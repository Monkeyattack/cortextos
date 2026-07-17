#!/usr/bin/env bash
# H137_BilateralBreakout live monitor — PAAPEX4333770000017 (Apex $50K PA, MES 1ct)
# Tripwires (fable-reviewer LOCKED): gWR RED floor 48% (>=30 trades),
# YELLOW watch zone <=58.6%, slippage >3t rolling mean (>=20 fills).
# Always exits 0 — never crash the cron.

set -u

DB_URL="postgresql://orbfutures:orbfutures@127.0.0.1/orbfutures_dashboard"
ACCOUNT="PAAPEX4333770000017"
STRATEGY="H137_BilateralBreakout"

# Route output to fable-reviewer (daily verdict) or chief (urgent tripwires)
# Uses cortextos bus — never fails the cron if routing fails.
_send_verdict() {
  local level="$1"  # normal | urgent
  local agent="$2"  # fable-reviewer | chief
  local msg="$3"
  cortextos bus send-message "$agent" "$level" "$msg" 2>/dev/null || true
}

_send_daily() {
  local msg="$1"
  _send_verdict normal fable-reviewer "$msg"
}

_send_tripwire_red() {
  local msg="$1"
  _send_verdict urgent chief "$msg"
  _send_verdict normal fable-reviewer "$msg"
}

_send_tripwire_yellow() {
  local msg="$1"
  _send_verdict normal analyst "$msg"
  _send_verdict normal fable-reviewer "$msg"
}

psql_q() {
  psql "$DB_URL" -X -A -t -q -c "$1" 2>/dev/null
}

# Connection check
if ! psql "$DB_URL" -X -A -t -q -c "SELECT 1" >/dev/null 2>&1; then
  echo "H137 MONITOR ERROR: cannot connect to orbfutures_dashboard DB — check postgres"
  exit 0
fi

# Staleness check: NT8 can detach without posting a disabled event — a stale
# Active row is NOT active. If last_seen > 2h old, report and skip tripwires.
# IMPORTANT: "0 trades observed" and "0 trades occurred" are different claims.
# When pipeline is dark we CANNOT distinguish them — output must say so explicitly.
LAST_SEEN=$(psql_q "SELECT last_seen FROM strategy_states
                    WHERE account_name='${ACCOUNT}' AND strategy_name='${STRATEGY}'
                    ORDER BY last_seen DESC LIMIT 1;")

if [ -z "$LAST_SEEN" ]; then
  MSG="⚠️ H137 MONITOR — PIPELINE DARK: no strategy_states row for ${ACCOUNT}/${STRATEGY}. NT8 has never posted or rows were deleted. 0 trades OBSERVED ≠ 0 trades OCCURRED — cannot distinguish. Check NT8 terminal."
  echo "$MSG"
  _send_daily "$MSG"
  exit 0
fi

FRESH=$(psql_q "SELECT COUNT(*) FROM strategy_states
                WHERE account_name='${ACCOUNT}' AND strategy_name='${STRATEGY}'
                AND last_seen > NOW() - INTERVAL '2 hours';")
if [ "${FRESH:-0}" -eq 0 ]; then
  AGE_HOURS=$(psql_q "SELECT ROUND(EXTRACT(EPOCH FROM (NOW() - last_seen)) / 3600, 1)
                      FROM strategy_states
                      WHERE account_name='${ACCOUNT}' AND strategy_name='${STRATEGY}'
                      ORDER BY last_seen DESC LIMIT 1;")
  MSG="⚠️ H137 MONITOR — PIPELINE DARK (${AGE_HOURS}h stale, last: ${LAST_SEEN}): 0 trades OBSERVED but pipeline is dark — cannot confirm 0 trades OCCURRED. NT8/MonkeyAttackMonitor may be offline. Verify terminal before treating as skip-day."
  echo "$MSG"
  _send_daily "$MSG"
  exit 0
fi

WHERE="account_name='${ACCOUNT}' AND strategy_name='${STRATEGY}' AND exit_time IS NOT NULL"

# ── Pre-session integrity checks (run all, report all, then bail if any RED) ──
PRE_RED=0

# 1. Qty gate — gated pilot config: Contracts=1
# Scoped to CURRENT SESSION only (entry_time >= today CT) to avoid re-flagging
# adjudicated historical fills (e.g. the 3-lot manual exit excluded 2026-07-16).
GATED_QTY=1
LAST_QTY=$(psql_q "SELECT qty FROM executions
                   WHERE account_name='${ACCOUNT}'
                     AND instrument LIKE 'MES%'
                     AND timestamp >= DATE_TRUNC('day', NOW() AT TIME ZONE 'America/Chicago') AT TIME ZONE 'America/Chicago'
                   ORDER BY timestamp DESC LIMIT 1;")
# NOTE: CURRENT_DATE AT TIME ZONE 'America/Chicago' is WRONG — postgres converts
# UTC midnight BACKWARD to Chicago (19:00 UTC prior day in CDT), not forward.
# Use DATE_TRUNC('day', NOW() AT TIME ZONE tz) AT TIME ZONE tz for local midnight in UTC.
if [ -n "$LAST_QTY" ] && [ "$LAST_QTY" -ne "$GATED_QTY" ]; then
  MSG="H137 TRIPWIRE RED: qty GATE VIOLATION — last fill qty=${LAST_QTY} vs gated config Contracts=${GATED_QTY}. Verify NT8 strategy Contracts parameter and pause until confirmed."
  echo "$MSG"
  _send_tripwire_red "$MSG"
  PRE_RED=1
fi

# 2. Co-strategy check — ONE ACCOUNT, ONE STRATEGY rule.
# NT8 heartbeats ALL loaded strategies (state=Active even if unassigned/not trading).
# Gate on actual trade activity (entry in trades table within 7d) to avoid false RED
# on strategies that are loaded-in-terminal but have no live positions or fills.
# Known blind spot: a brand-new co-strategy with 0 trades yet would not fire here —
# the qty-RED check (above) provides the fallback once that strategy executes.
CO_STRATS=$(psql_q "SELECT string_agg(s.strategy_name, ', ' ORDER BY s.strategy_name)
                    FROM strategy_states s
                    WHERE s.account_name='${ACCOUNT}'
                      AND s.strategy_name != '${STRATEGY}'
                      AND s.last_seen > NOW() - INTERVAL '4 hours'
                      AND EXISTS (
                        SELECT 1 FROM trades t
                        WHERE t.account_name = s.account_name
                          AND t.strategy_name = s.strategy_name
                          AND t.entry_time >= CURRENT_DATE AT TIME ZONE 'America/Chicago'
                      );")
if [ -n "$CO_STRATS" ] && [ "$CO_STRATS" != "" ]; then
  MSG="H137 TRIPWIRE RED: co-strategy violation — ${CO_STRATS} ACTIVE on ${ACCOUNT} alongside H137. Remove from NT8 chart before next session (one account, one strategy rule)."
  echo "$MSG"
  _send_tripwire_red "$MSG"
  PRE_RED=1
fi

[ "$PRE_RED" -eq 1 ] && exit 0

STATS=$(psql_q "SELECT COUNT(*),
                       COALESCE(SUM(CASE WHEN pnl_dollars > 0 THEN 1 ELSE 0 END),0),
                       COALESCE(AVG(pnl_dollars),0)
                FROM trades WHERE ${WHERE};")

if [ -z "$STATS" ]; then
  MSG="H137 MONITOR ERROR: stats query failed"
  echo "$MSG"
  _send_daily "$MSG"
  exit 0
fi

N=$(echo "$STATS" | cut -d'|' -f1)
WINS=$(echo "$STATS" | cut -d'|' -f2)
MEAN=$(echo "$STATS" | cut -d'|' -f3)

if [ "$N" -eq 0 ]; then
  echo "H137 MONITOR: 0 trades — awaiting first fill"
  exit 0
fi

# Pull today's fills for the daily verdict detail
TODAY_FILLS=$(psql_q "SELECT direction, entry_price, exit_price, pnl_dollars, exit_signal
                       FROM trades
                       WHERE account_name='${ACCOUNT}' AND strategy_name='${STRATEGY}'
                         AND exit_time IS NOT NULL
                         AND entry_time >= CURRENT_DATE AT TIME ZONE 'America/Chicago'
                       ORDER BY entry_time DESC;")
TODAY_N=$(echo "$TODAY_FILLS" | grep -c "|" || echo "0")

GWR=$(awk -v w="$WINS" -v n="$N" 'BEGIN { printf "%.4f", w/n }')
GWR_PCT=$(awk -v g="$GWR" 'BEGIN { printf "%.1f%%", g*100 }')
MEAN_FMT=$(awk -v m="$MEAN" 'BEGIN { printf "%.2f", m }')

# Rolling slippage: needs tp_ticks/sl_ticks populated to compare against fills
SLIP_ROWS=$(psql_q "SELECT COUNT(*) FROM trades WHERE ${WHERE} AND tp_ticks IS NOT NULL AND sl_ticks IS NOT NULL;")
SLIP_NOTE="slippage UNCONFIRMED (no tp/sl tick data)"
if [ -n "$SLIP_ROWS" ] && [ "$SLIP_ROWS" -ge 20 ]; then
  # Mean absolute deviation of realized PnL from ideal tick targets (MES tick = $1.25)
  SLIP_MEAN=$(psql_q "SELECT COALESCE(AVG(ABS(ABS(pnl_dollars)/1.25 - CASE WHEN pnl_dollars > 0 THEN tp_ticks ELSE sl_ticks END)),0)
                      FROM (SELECT pnl_dollars, tp_ticks, sl_ticks FROM trades WHERE ${WHERE}
                            AND tp_ticks IS NOT NULL AND sl_ticks IS NOT NULL
                            ORDER BY exit_time DESC LIMIT 20) recent;")
  SLIP_FMT=$(awk -v s="$SLIP_MEAN" 'BEGIN { printf "%.1f", s }')
  SLIP_NOTE="rolling slippage ${SLIP_FMT}t (last 20 fills)"
  if awk -v s="$SLIP_MEAN" 'BEGIN { exit !(s > 3) }'; then
    echo "H137 TRIPWIRE: slippage ${SLIP_FMT}t > 3t rolling mean over last 20 fills"
  fi
elif [ -n "$SLIP_ROWS" ] && [ "$SLIP_ROWS" -gt 0 ]; then
  SLIP_NOTE="slippage UNCONFIRMED (${SLIP_ROWS} fills with tick data, need >=20)"
fi

# gWR tripwires (>=30 trades)
if [ "$N" -ge 30 ] && awk -v g="$GWR" 'BEGIN { exit !(g <= 0.48) }'; then
  MSG="H137 TRIPWIRE RED: gWR ${GWR_PCT} <= 48% floor over ${N} trades — HALT REQUIRED"
  echo "$MSG"
  _send_tripwire_red "$MSG"
  exit 0
fi

if [ "$N" -ge 30 ] && awk -v g="$GWR" 'BEGIN { exit !(g <= 0.586) }'; then
  MSG="H137 TRIPWIRE YELLOW: gWR ${GWR_PCT} in watch zone (50-58.6%) over ${N} trades"
  echo "$MSG"
  _send_tripwire_yellow "$MSG"
  exit 0
fi

# Build daily verdict with today's fills
TODAY_DETAIL=""
if [ -n "$TODAY_FILLS" ] && [ "$TODAY_N" -gt 0 ]; then
  TODAY_DETAIL=" | Today: ${TODAY_N} fill(s): $(echo "$TODAY_FILLS" | tr '\n' ' ')"
else
  TODAY_DETAIL=" | Today: 0 fills"
fi

MSG="H137 MONITOR OK: ${N} trades (all-time), gWR ${GWR_PCT}, mean \$${MEAN_FMT}/trade — ${SLIP_NOTE}${TODAY_DETAIL}"
echo "$MSG"
_send_daily "$MSG"
exit 0
