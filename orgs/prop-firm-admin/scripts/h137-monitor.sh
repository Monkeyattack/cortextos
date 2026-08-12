#!/usr/bin/env bash
# h137-monitor.sh — H137 EOD monitoring script
# Fires at 21:30 UTC (4:30 PM CT) post-close, Mon-Fri.
# Checks: strategy attachment, today's trade count, tripwire logic.
# Output: OK / TRIPWIRE YELLOW / TRIPWIRE RED
DRYRUN="${DRYRUN:-0}"

DB="postgresql://orbfutures:orbfutures@127.0.0.1/orbfutures_dashboard"
PILOT_ACCOUNT="PAAPEX4333770000017"
PILOT_STRATEGY="H137_BilateralBreakout"
CT_TIME=$(TZ=America/Chicago date '+%I:%M %p CT')

psql_q() { psql "$DB" -X -A -t -q -c "$1" 2>/dev/null; }

if ! psql "$DB" -X -A -t -q -c "SELECT 1" >/dev/null 2>&1; then
  echo "TRIPWIRE RED: cannot connect to DB"
  exit 1
fi

# Strategy attachment check
STRAT_AGE=$(psql_q "
  SELECT ROUND(EXTRACT(EPOCH FROM (NOW() - last_seen)) / 60)::int
  FROM strategy_states
  WHERE account_name='${PILOT_ACCOUNT}' AND strategy_name='${PILOT_STRATEGY}'
  ORDER BY last_seen DESC LIMIT 1;")

# Trade count today (excluding Chris-excluded off-config trades)
TRADE_COUNT=$(psql_q "
  SELECT COUNT(*) FROM trades t
  WHERE t.account_name='${PILOT_ACCOUNT}'
    AND t.entry_time >= NOW()::date
    AND t.entry_time < NOW()::date + INTERVAL '1 day'
    AND NOT EXISTS (SELECT 1 FROM h137_trade_exclusions e WHERE e.trade_id = t.id);")

TRADE_COUNT="${TRADE_COUNT:-0}"

# Model-match series count (lifetime, exclusions respected)
SERIES_COUNT=$(psql_q "
  SELECT COUNT(*) FROM trades t
  WHERE t.account_name='${PILOT_ACCOUNT}'
    AND t.strategy_name='${PILOT_STRATEGY}'
    AND NOT EXISTS (SELECT 1 FROM h137_trade_exclusions e WHERE e.trade_id = t.id);")

SERIES_COUNT="${SERIES_COUNT:-0}"

# Open positions — use trades table (exit_time IS NULL) not positions table.
# Positions table can carry stale qty rows after exit; trades exit_time is authoritative.
OPEN_QTY=$(psql_q "
  SELECT COUNT(*) FROM trades
  WHERE account_name='${PILOT_ACCOUNT}'
    AND strategy_name='${PILOT_STRATEGY}'
    AND entry_time >= NOW()::date
    AND exit_time IS NULL;")

OPEN_QTY="${OPEN_QTY:-0}"

# PnL today (closed trades)
PNL_TODAY=$(psql_q "
  SELECT COALESCE(SUM(pnl_dollars), 0)::numeric(10,2)
  FROM trades
  WHERE account_name='${PILOT_ACCOUNT}'
    AND entry_time >= NOW()::date
    AND exit_time IS NOT NULL;")

PNL_TODAY="${PNL_TODAY:-0}"

# --- Tripwire logic ---

# RED: strategy detached (stale >2h or absent)
if [ -z "$STRAT_AGE" ] || [ "${STRAT_AGE:-0}" -gt 120 ]; then
  echo "TRIPWIRE RED (${CT_TIME}): H137_BilateralBreakout on ${PILOT_ACCOUNT} DETACHED (age=${STRAT_AGE:-absent} min). NT8 may be offline."
  exit 0
fi

# YELLOW: open position at EOD (should be flat)
if [ "${OPEN_QTY}" -gt 0 ]; then
  echo "TRIPWIRE YELLOW (${CT_TIME}): Open position at EOD — ${OPEN_QTY} contracts still open on ${PILOT_ACCOUNT}. Verify flat before tomorrow."
  exit 0
fi

# ── Zero-trade drought tripwire ───────────────────────────────────────────────
# The monitor above answers ONE question — is the strategy attached and fresh —
# and then prints OK. On 2026-08-11 it printed
#   "OK: H137 Day closed - 0 trades fired today. Strategy fresh (0min). Flat."
# on the THIRD consecutive zero-trade session, after four straight sessions of
# seven trades a day (Aug 3,4,5,6). Attached and fresh were both true. Trading
# was not happening. Liveness is not function, and only liveness was visible.
#
# So this asks the SECOND question: is it producing?
#
# Counts consecutive ELIGIBLE sessions with zero trades, not days since the last
# trade. H137 skips Fridays by config (SkipFridays since 374f375), so a
# days-since counter alerts on a day the strategy was correctly silent. Weekends
# and Fridays are not sessions it was eligible to trade.
#
# Threshold 2, from observed behaviour rather than a round number: 70/70/74/140
# orders on Aug 3-6, then zero. Two consecutive zero-sessions is outside its
# range — though note zero-sessions ALONE are ordinary: 5 of the 16 eligible
# sessions to 2026-08-11 were zero. It is the CONSECUTIVE pair that is new.
#
# ── WHAT THIS TRIPWIRE CANNOT SEE, and why the wording below is deliberately
#    weaker than an alarm ──────────────────────────────────────────────────────
# Corrected 2026-08-11 after this fired and I escalated it to Chris as breakage.
# It was not breakage. Chris and analyst diagnosed the real cause from the NT8
# Print output: VIX passed (15.46), the range formed (21pt, 7771.75-7792.75),
# and no bilateral breakout occurred — so no entry triggered. Zero trades was
# CORRECT. My first version of this comment described those sessions as "a live
# strategy doing nothing while reporting healthy"; that was wrong and is the
# error this note exists to stop the next reader repeating.
#
# The tripwire counts TRADES. It cannot see the TRIGGER CONDITION, so it cannot
# distinguish:
#     "no breakout fired"            -> correct behaviour, no action
#     "breakout fired, trade missing" -> a real execution gap
# Nothing persists that condition: `events` carries only CONN_*/STARTUP/SHUTDOWN
# /EOD, `brain_bar_states` is empty, and trades/orders record only what fired.
# H137 Prints its decisions but nothing ingests Prints.
#
# Fixing that properly = have H137 POST per-session state (range_formed,
# breakout_fired, vix, skip_reason) using the PostToDashboard pattern already
# proven in MarketOpenVolatility.cs:1362 — Task.Run + swallow-all catch, so
# diagnostics can never crash NT8. That is a live-capital .cs change: needs
# chief routing, Chris GO and a fable-reviewer gate. Agreed with analyst
# 2026-08-11 as a next-sprint item, NOT an emergency patch.
#
# Until then this reports what it actually knows and says so.
DROUGHT_THRESHOLD="${H137_DROUGHT_THRESHOLD:-2}"
DROUGHT=$(psql_q "
  WITH bounds AS (
    -- Everything in EASTERN, the market's clock. The DB runs UTC, so
    -- CURRENT_DATE rolls over at 19:00/20:00 ET — i.e. in the middle of the
    -- evening, hours before the next session exists.
    --
    -- BUG FIXED 2026-08-11: the previous version ran to CURRENT_DATE inclusive
    -- and so counted a session that HAD NOT HAPPENED YET as a zero-trade
    -- session. Run at 21:25 CT on Tue Aug 11 it reported THREE consecutive
    -- zeros (Aug 10, Aug 11, and a phantom Aug 12) when the true answer was
    -- two. An off-by-one that inflates a tripwire is how a quiet week turns
    -- into a false alarm.
    --
    -- A session only counts once it has ENDED. H137 flattens at 15:45 ET, so
    -- today is eligible to be judged only after 16:00 ET.
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS et_today,
           (now() AT TIME ZONE 'America/New_York')::time AS et_now
  ),
  eligible AS (
    SELECT d::date AS session_date
    FROM bounds b,
         generate_series(
           b.et_today - INTERVAL '30 days',
           CASE WHEN b.et_now >= TIME '16:00' THEN b.et_today::timestamp
                ELSE (b.et_today - INTERVAL '1 day') END,
           INTERVAL '1 day') d
    WHERE EXTRACT(ISODOW FROM d) BETWEEN 1 AND 4      -- Mon-Thu: Fri is skipped by config
  ),
  traded AS (
    -- Session date in ET too, so a trade cannot be attributed to the wrong
    -- session by a UTC rollover.
    SELECT (t.entry_time AT TIME ZONE 'America/New_York')::date AS session_date, COUNT(*) AS n
    FROM trades t
    WHERE t.account_name='${PILOT_ACCOUNT}' AND t.strategy_name='${PILOT_STRATEGY}'
      AND NOT EXISTS (SELECT 1 FROM h137_trade_exclusions e WHERE e.trade_id = t.id)
    GROUP BY 1
  ),
  joined AS (
    SELECT e.session_date, COALESCE(tr.n,0) AS n
    FROM eligible e LEFT JOIN traded tr USING (session_date)
    ORDER BY e.session_date DESC
  ),
  streak AS (
    SELECT session_date, n,
           SUM(CASE WHEN n > 0 THEN 1 ELSE 0 END) OVER (ORDER BY session_date DESC) AS grp
    FROM joined
  )
  SELECT COUNT(*) FROM streak WHERE grp = 0;")
DROUGHT="${DROUGHT:-0}"

if [ "${DROUGHT}" -ge "${DROUGHT_THRESHOLD}" ]; then
  echo "TRIPWIRE NOTICE (${CT_TIME}): H137 traded ZERO on ${DROUGHT} consecutive eligible sessions (Mon-Thu; Fridays are a config skip). CAUSE UNKNOWN — this is not an alarm. Strategy is attached and fresh (${STRAT_AGE}min), so it is not a detach, but no trigger data is persisted and this check counts TRADES only. It cannot tell 'no breakout fired' (correct behaviour) from 'breakout fired but the trade is missing' (a real execution gap). Zero-sessions are ordinary for H137 on their own; the consecutive run is what is being reported. NEXT STEP: read the NT8 output-window Print lines for those sessions — H137 prints its VIX gate, range formation and skip reasons. To make this check self-sufficient see option (A) in the comment block above (H137 posts per-session state via the PostToDashboard pattern from MarketOpenVolatility.cs:1362; live-capital .cs change, agreed with analyst 2026-08-11 as a next-sprint item)."
  exit 0
fi

# OK
if [ "${TRADE_COUNT}" -gt 0 ]; then
  echo "OK (${CT_TIME}): H137 Day closed. ${TRADE_COUNT} trade(s). PnL today: \$${PNL_TODAY}. Series: ${SERIES_COUNT}/30. Strategy fresh (${STRAT_AGE}min). Flat at EOD."
else
  echo "OK (${CT_TIME}): H137 Day closed — 0 trades fired today. Series: ${SERIES_COUNT}/30. Strategy fresh (${STRAT_AGE}min). Flat."
fi
