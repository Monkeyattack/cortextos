#!/usr/bin/env bash
# H137_BilateralBreakout live monitor — PAAPEX4333770000017 (Apex $50K PA, MES 1ct)
# Tripwires (fable-reviewer LOCKED): gWR RED floor 48% (>=30 trades),
# YELLOW watch zone <=58.6%, slippage >3t rolling mean (>=20 fills).
# Always exits 0 — never crash the cron.

set -u

DB_URL="postgresql://orbfutures:orbfutures@127.0.0.1/orbfutures_dashboard"
ACCOUNT="PAAPEX4333770000017"
STRATEGY="H137_BilateralBreakout"

psql_q() {
  psql "$DB_URL" -X -A -t -q -c "$1" 2>/dev/null
}

# Connection check
if ! psql "$DB_URL" -X -A -t -q -c "SELECT 1" >/dev/null 2>&1; then
  echo "H137 MONITOR ERROR: cannot connect to orbfutures_dashboard DB — check postgres"
  exit 0
fi

WHERE="account_name='${ACCOUNT}' AND strategy_name='${STRATEGY}' AND exit_time IS NOT NULL"

STATS=$(psql_q "SELECT COUNT(*),
                       COALESCE(SUM(CASE WHEN pnl_dollars > 0 THEN 1 ELSE 0 END),0),
                       COALESCE(AVG(pnl_dollars),0)
                FROM trades WHERE ${WHERE};")

if [ -z "$STATS" ]; then
  echo "H137 MONITOR ERROR: stats query failed"
  exit 0
fi

N=$(echo "$STATS" | cut -d'|' -f1)
WINS=$(echo "$STATS" | cut -d'|' -f2)
MEAN=$(echo "$STATS" | cut -d'|' -f3)

if [ "$N" -eq 0 ]; then
  echo "H137 MONITOR: 0 trades — awaiting first fill"
  exit 0
fi

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
  echo "H137 TRIPWIRE RED: gWR ${GWR_PCT} <= 48% floor over ${N} trades — HALT REQUIRED"
  exit 0
fi

if [ "$N" -ge 30 ] && awk -v g="$GWR" 'BEGIN { exit !(g <= 0.586) }'; then
  echo "H137 TRIPWIRE YELLOW: gWR ${GWR_PCT} in watch zone (50-58.6%) over ${N} trades"
  exit 0
fi

echo "H137 MONITOR OK: ${N} trades, gWR ${GWR_PCT}, mean \$${MEAN_FMT}/trade — ${SLIP_NOTE}"
exit 0
