#!/usr/bin/env bash
# h137-open-position-check.sh — determine whether an account/instrument is FLAT.
#
# STATUS: NOT WIRED IN. This is a standalone, reviewable replacement for the
# open-position check in h137-monitor.sh:48-55. Chief GO 2026-08-12 to write it;
# fable-reviewer gates before it is wired into the live gate. Do not call this
# from h137-monitor.sh until that review passes.
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
# h137-monitor.sh:48-55 counts open positions as:
#     SELECT COUNT(*) FROM trades WHERE ... AND exit_time IS NULL
# Measured 2026-08-12 across the whole table: 763 trades, 763 with a NON-NULL
# exit_time, ZERO null. That predicate can never be true, so the count is
# structurally always 0 and the monitor reports "Flat" unconditionally. It has
# never once measured flatness. It is doubly impossible: a trades row is only
# written ON EXIT, so an open position has no row to test at all.
#
# That is FAIL-OPEN on a live-capital gate — the permissive answer is the one
# that persists, and a frozen "Flat" is indistinguishable from a real one.
#
# ── DESIGN (chief-approved 2026-08-12) ───────────────────────────────────────
# EXECUTIONS-PRIMARY, POSITIONS-ADVISORY, DISAGREEMENT IS ITSELF THE SIGNAL.
#
#   executions  net signed quantity per account+instrument. A genuine flat nets
#               to zero. This is the authority: it caught the 2026-08-06 19:50Z
#               closes on all seven funded accounts correctly.
#   positions   latest row per account+instrument. ADVISORY ONLY — it keeps
#               stale non-zero rows when a close write is lost (defect
#               task_1785869632671_bnm0ym). On 2026-08-12 it showed seven funded
#               accounts short MES for six days after they had actually gone
#               flat. Trusting it as primary would fail CLOSED — safer, but it
#               would fire false alarms daily, which is the alert-fatigue
#               mechanism that task_1785852761447_2v0ycq was closed over.
#
# We do NOT silently pick one. When the two sources disagree, that disagreement
# is reported — because a disagreement is the observable symptom of the
# lost-write defect, and today it is invisible.
#
# EXPLICITLY NOT USED: the trades table. Write-on-exit semantics mean it cannot
# answer "is something open right now" no matter how the query is phrased.
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0  FLAT      — executions net to zero for every instrument on the account
#   2  OPEN      — executions net non-zero (a real open position)
#   3  DISAGREE  — executions and positions disagree; state is UNKNOWN, treat as
#                  open and investigate. Never treat 3 as flat.
#   1  ERROR     — could not measure (DB unreachable, bad args). Fail-closed:
#                  an unmeasurable account is NOT a flat account.
#
# ── RESIDUAL LIMITS — READ BEFORE TRUSTING A FLAT ────────────────────────────
# Named at fable-reviewer's instruction 2026-08-12. These are not TODOs; they are
# the boundary of what any in-record rule can establish.
#
# 1. THE VALIDATED ANCHOR PROVES CONSISTENCY, NOT GROUND TRUTH. An executions net
#    of zero at instant T only proves flatness if the record STARTED flat. Two
#    independent sources agreeing at zero is strong evidence and it is the best
#    available from inside the data — but an account born mid-position has no
#    valid anchor anywhere, will correctly refuse (exit 1), and must be resolved
#    with OPEN_CHECK_EPOCH from a broker statement. Refusing is the right answer
#    there; a number would be invention.
#
# 2. A DOUBLE-DEFECT COINCIDENCE DEFEATS THIS ENTIRELY. If a wrong zero-write
#    lands at the same instant that the executions net happens to be zero, both
#    sources agree at zero and the anchor validates — while the true position is
#    open. No rule computed from these two tables can detect that; they are the
#    only witnesses and both are wrong at once. OPEN_CHECK_EPOCH with external
#    evidence is the only escape. Stated so nobody later reads a FLAT from this
#    script as proof rather than as strong corroborated evidence.
#
# 3. THE FAILURE DIRECTIONS ARE NOT SYMMETRIC AND WERE CHOSEN DELIBERATELY.
#    Unanchored netting over-reported OPEN (false positive, fails safe, causes
#    alert fatigue). The first anchor under-reported FLAT (false negative, hides
#    exposure — the dangerous direction, and it shipped to a gate before being
#    caught on Sim3). This version prefers UNMEASURABLE and DISAGREE over a
#    confident answer in every ambiguous case.
#
# Usage:  h137-open-position-check.sh <account_name> [--json]

set -uo pipefail

DB="${ORB_DB:-}"
if [[ -z "$DB" ]]; then echo "[open-check] ERROR: ORB_DB not set" >&2; exit 1; fi
ACCOUNT="${1:-}"
JSON=0
[[ "${2:-}" == "--json" ]] && JSON=1

if [[ -z "$ACCOUNT" ]]; then
  echo "usage: $(basename "$0") <account_name> [--json]" >&2
  exit 1
fi

# psql_q MUST propagate psql's exit status. The first version swallowed stderr
# and returned an empty string on any query-level failure, and empty parsed as
# flat — so a statement error, a per-query timeout or a lock acquired AFTER the
# SELECT 1 reachability probe all read as FLAT on a live-capital gate. That is
# the exact fail-open class this script exists to remove, and it was living
# inside it. Found by fable-reviewer 2026-08-12 with a one-line live probe
# (account name "X'BROKEN" forces a syntax error past the reachability check).
# Callers must use `VAR=$(psql_q "...") || exit 1`.
psql_q() {
  local out status
  out=$(psql "$DB" -X -A -t -q -F'|' -c "$1" 2>/dev/null); status=$?
  if (( status != 0 )); then
    echo "[open-check] ERROR: query failed (psql exit ${status}) — state UNKNOWN, NOT flat" >&2
    return "$status"
  fi
  printf '%s' "$out"
}

if ! psql "$DB" -X -A -t -q -c "SELECT 1" >/dev/null 2>&1; then
  echo "[open-check] ERROR: cannot reach DB — state UNKNOWN, not flat" >&2
  exit 1
fi

# ── PRIMARY: net signed quantity from executions ─────────────────────────────
# Long adds, Short subtracts. "Flat" direction rows are position-closing writes
# whose quantity is the size being closed, so they are netted against the sign
# of what is currently held rather than assumed. We therefore compute the net
# from Long/Short only and treat a Flat row as an explicit zeroing marker.
# ── EPOCH ANCHOR ─────────────────────────────────────────────────────────────
# Netting is only valid FROM A KNOWN-FLAT STARTING POINT. Netting all history
# assumes the record begins at flat, and where it does not, the net is offset by
# the unrecorded opening quantity FOREVER and reads as a permanent phantom
# position.
#
# Found 2026-08-12 against this script's own output: MFFUSFFLX450774019 (a
# FUNDED account) nets +2 on MES 09-26, but its first recorded execution is a
# Long 2 with no prior offsetting short and its flat points sit at +2 from then
# on. The position was opened BEFORE the executions record begins. Unanchored,
# this script reports that account OPEN +2 every single day, forever, wrongly —
# which is precisely the alert-fatigue mechanism that gets real alerts ignored.
# Same artifact on PPNTF100024895000002 (+6) and TAKEPROFITPRO392542906 (+1).
#
# ANCHOR RULE: the most recent positions row where qty = 0 for that
# account+instrument. fable-reviewer's refinement, and it matters — the anchor
# must be agreement AT ZERO specifically, never agreement at an arbitrary value,
# because the positions table is known to carry stale non-zero rows
# (task_1785869632671_bnm0ym). A zero row is the one value a stale-write defect
# cannot manufacture: lost writes leave rows non-zero, never zero.
#
# NO ANCHOR = NO ANSWER. If no qty=0 row exists for an instrument, this script
# REFUSES that account (exit 1, unmeasurable) rather than emitting a number it
# cannot justify. Refusing is honest; a standing false +2 is not.
#
# Override per account with OPEN_CHECK_EPOCH=<ISO timestamp> when the anchor is
# known out-of-band (e.g. a broker statement confirming flat at a point in time).
EPOCH_OVERRIDE="${OPEN_CHECK_EPOCH:-}"

# Instruments this account has ever traded, with a VALIDATED anchor.
#
# VALIDATION IS THE WHOLE POINT (2026-08-12, second revision). The first version
# took "the most recent positions row where qty = 0" as the anchor. That was an
# under-implementation of the rule and it produced a FALSE FLAT on live data.
#
# Sim3 MNQ 09-26: positions wrote Short|0 at 2026-08-12 04:25:34Z while the
# executions net at that instant was -1, and wrote Long|0 at 2026-08-05 18:31:34Z
# at the exact moment executions opened a short. Anchoring on either zero
# discards every execution before it — including the unmatched short — and the
# check reports FLAT on an account that is short 1.
#
# The premise the first version rested on was that a lost write leaves a
# positions row NON-zero and therefore a zero row cannot be manufactured by the
# stale-write defect. True for LOST writes. Sim3 is a WRONG write, and no amount
# of trusting a single source detects that.
#
# So: a candidate anchor is only valid when BOTH sources agree AND the value they
# agree on is zero. Walk back through positions-zero rows, newest first, and take
# the first whose timestamp also has an executions net of zero. That is a real
# flat, corroborated twice. Anything less is one source's word.
#
# This is a FALSE-NEGATIVE fix on an open-position check, which is the dangerous
# direction — the previous behaviour hid exposure rather than inventing it.
ANCHOR_ROWS=$(psql_q "
  WITH insts AS (
    SELECT DISTINCT instrument FROM executions WHERE account_name = '${ACCOUNT}'
  ),
  candidates AS (
    SELECT i.instrument, p.timestamp AS ts
    FROM insts i
    JOIN positions p
      ON p.account_name = '${ACCOUNT}' AND p.instrument = i.instrument AND p.qty = 0
  ),
  validated AS (
    SELECT c.instrument, c.ts,
           (SELECT COALESCE(SUM(CASE WHEN e.direction = 'Long'  THEN e.qty
                                     WHEN e.direction = 'Short' THEN -e.qty
                                     ELSE 0 END), 0)
              FROM executions e
             WHERE e.account_name = '${ACCOUNT}'
               AND e.instrument   = c.instrument
               AND e.timestamp   <= c.ts) AS exec_net_at_ts
    FROM candidates c
  )
  SELECT i.instrument,
         (SELECT MAX(v.ts) FROM validated v
           WHERE v.instrument = i.instrument AND v.exec_net_at_ts = 0) AS anchor_ts
  FROM insts i
  ORDER BY i.instrument;") || exit 1

UNANCHORED=""
declare -A ANCHOR=()
while IFS='|' read -r inst ats; do
  [[ -z "$inst" ]] && continue
  if [[ -n "$EPOCH_OVERRIDE" ]]; then
    ANCHOR["$inst"]="$EPOCH_OVERRIDE"
  elif [[ -n "$ats" ]]; then
    ANCHOR["$inst"]="$ats"
  else
    UNANCHORED="${UNANCHORED}${inst} "
  fi
done < <(printf '%s\n' "$ANCHOR_ROWS")

if [[ -n "$UNANCHORED" ]]; then
  echo "[open-check] ${ACCOUNT}: UNMEASURABLE — no flat anchor for: ${UNANCHORED% }" >&2
  echo "[open-check] For these instruments there is NO timestamp at which BOTH sources say zero." >&2
  echo "[open-check] Either no positions row is at qty=0, or every such row is contradicted by a" >&2
  echo "[open-check] non-zero executions net at that instant (positions asserting flat while the" >&2
  echo "[open-check] executions record says otherwise — observed on Sim3 MNQ 09-26, 2026-08-12)." >&2
  echo "[open-check] Without a corroborated flat there is no valid origin to net from, and any" >&2
  echo "[open-check] number would be one source's unverified word. Refusing to guess." >&2
  echo "[open-check] Supply OPEN_CHECK_EPOCH=<ISO ts> if flat is known from an out-of-band source." >&2
  exit 1
fi

# Net ONLY executions at or after each instrument's anchor.
NET_ROWS=""
for inst in "${!ANCHOR[@]}"; do
  row=$(psql_q "
    SELECT '${inst}',
           SUM(CASE WHEN direction = 'Long'  THEN qty
                    WHEN direction = 'Short' THEN -qty
                    ELSE 0 END) AS net_qty,
           MAX(timestamp) AS last_exec,
           SUM(CASE WHEN direction = 'Flat' THEN 1 ELSE 0 END) AS flat_markers
    FROM executions
    WHERE account_name = '${ACCOUNT}'
      AND instrument   = '${inst}'
      AND timestamp    > '${ANCHOR[$inst]}';") || exit 1
  net=$(printf '%s' "$row" | cut -d'|' -f2)
  flats=$(printf '%s' "$row" | cut -d'|' -f4)
  if [[ "${net:-0}" -ne 0 || "${flats:-0}" -gt 0 ]]; then
    NET_ROWS="${NET_ROWS}${row}"$'\n'
  fi
done
NET_ROWS="${NET_ROWS%$'\n'}"

# ── ADVISORY: latest positions row per instrument ────────────────────────────
POS_ROWS=$(psql_q "
  SELECT DISTINCT ON (instrument) instrument, direction, qty, timestamp
  FROM positions
  WHERE account_name = '${ACCOUNT}'
  ORDER BY instrument, timestamp DESC;") || exit 1

# ── Compare ──────────────────────────────────────────────────────────────────
EXEC_OPEN=0        # instruments the executions net says are open
POS_OPEN=0         # instruments the positions table claims are open
DISAGREE_LIST=""
OPEN_LIST=""

declare -A EXEC_NET=()
while IFS='|' read -r inst net _last _flats; do
  [[ -z "$inst" ]] && continue
  EXEC_NET["$inst"]="$net"
  if [[ "${net:-0}" -ne 0 ]]; then
    EXEC_OPEN=$((EXEC_OPEN + 1))
    OPEN_LIST="${OPEN_LIST}${inst}:${net} "
  fi
done < <(printf '%s\n' "$NET_ROWS")

while IFS='|' read -r inst dir qty ts; do
  [[ -z "$inst" ]] && continue
  net="${EXEC_NET[$inst]:-0}"

  # Signed quantity the positions table is asserting, so it can be compared
  # against the executions net on the same scale. A Short row of 5 and an
  # executions net of -5 agree; a Short row of 1 against a net of -3 does not.
  pos_signed=0
  if [[ "${qty:-0}" -ne 0 ]]; then
    case "$dir" in
      Long)  pos_signed="$qty" ;;
      Short) pos_signed="-$qty" ;;
      *)     pos_signed="$qty" ;;   # unknown direction — compare magnitude only
    esac
    POS_OPEN=$((POS_OPEN + 1))
  fi

  # THREE ways these sources can disagree. All three are the same underlying
  # signal — one of the two writers lost or mangled an event — and all three
  # must be visible. Only the first was handled before 2026-08-12; chief
  # required the other two closed before review, because a check that reports
  # agreement on a case it never examined is the failure mode this whole script
  # exists to remove.
  if [[ "${qty:-0}" -ne 0 && "${net:-0}" -eq 0 ]]; then
    # (1) positions says open, executions net flat -> likely lost zero-write
    DISAGREE_LIST="${DISAGREE_LIST}${inst}(pos=${dir} ${qty} @${ts}, exec_net=0) "
  elif [[ "${qty:-0}" -eq 0 && "${net:-0}" -ne 0 ]]; then
    # (2) positions says flat, executions say open -> a position write was lost,
    # or an execution landed with no corresponding position update. Reported
    # even though the executions net already forces an OPEN verdict, because
    # WHICH source is wrong is the diagnostic.
    DISAGREE_LIST="${DISAGREE_LIST}${inst}(pos=flat @${ts}, exec_net=${net}) "
  elif [[ "${qty:-0}" -ne 0 && "${pos_signed}" -ne "${net:-0}" ]]; then
    # (3) both say open, at DIFFERENT sizes or opposite directions.
    # NO LIVE INSTANCE has ever been observed. An earlier version of this
    # comment cited SimSim2 MES 09-26 as an example; that was wrong — SimSim2 is
    # a branch (2) case, and the error came from reading a "WHERE qty <> 0"
    # query as if it showed the latest row. Exercised by synthetic fixture only
    # (see tests/ note in the gate submission, 2026-08-12).
    DISAGREE_LIST="${DISAGREE_LIST}${inst}(pos=${dir} ${qty} [signed ${pos_signed}] @${ts}, exec_net=${net}) "
  fi
done < <(printf '%s\n' "$POS_ROWS")

# An instrument that executions call open but that has NO positions row at all
# is also a disagreement — the positions writer never saw it. Without this the
# instrument would simply be absent from the loop above and pass unexamined.
for inst in "${!EXEC_NET[@]}"; do
  net="${EXEC_NET[$inst]}"
  [[ "${net:-0}" -eq 0 ]] && continue
  if ! printf '%s\n' "$POS_ROWS" | cut -d'|' -f1 | grep -qxF "$inst"; then
    DISAGREE_LIST="${DISAGREE_LIST}${inst}(no positions row at all, exec_net=${net}) "
  fi
done

if (( JSON == 1 )); then
  printf '{"account":"%s","exec_open_instruments":%d,"positions_open_instruments":%d,"disagreements":"%s","open":"%s"}\n' \
    "$ACCOUNT" "$EXEC_OPEN" "$POS_OPEN" "${DISAGREE_LIST% }" "${OPEN_LIST% }"
fi

if (( EXEC_OPEN > 0 )); then
  echo "[open-check] ${ACCOUNT}: OPEN — executions net non-zero: ${OPEN_LIST% }"
  [[ -n "$DISAGREE_LIST" ]] && echo "[open-check] ${ACCOUNT}: also DISAGREE: ${DISAGREE_LIST% }"
  exit 2
fi

if [[ -n "$DISAGREE_LIST" ]]; then
  echo "[open-check] ${ACCOUNT}: DISAGREE — positions table claims open, executions net to flat: ${DISAGREE_LIST% }"
  echo "[open-check] state is UNKNOWN. Treat as open. Likely a lost zero-write (task_1785869632671_bnm0ym)."
  exit 3
fi

echo "[open-check] ${ACCOUNT}: FLAT — executions net to zero on every instrument, positions agrees"
exit 0
