#!/usr/bin/env bash
# h137-cluster-exit-watch.sh — watch the 2026-08-04 MES 7779.50 LONG signal cluster.
#
# Chief directive 2026-08-04: the pilot (PAAPEX...017) exited at 18:31 UTC with a bare
# exit_signal="Close" — the manual-flatten marker. If Chris is flattening by hand, the
# remaining accounts should follow the same way. Watch for that pattern.
#
# Fail-closed: if the DB or the NT8 endpoint cannot be reached, that is reported as a
# problem, never as "nothing happening". An empty result from a broken instrument is the
# failure mode this whole day has been about.
#
# Exit 0 = reported cleanly (cluster may be open or flat). Exit 2 = could not determine.
set -uo pipefail

DB="${ORB_DB:-}"
if [[ -z "$DB" ]]; then echo "[cluster-watch] ERROR: ORB_DB not set" >&2; exit 2; fi
ENTRY="7779.5"
NT8_URL="https://dashboard.profithits.app/api/nt8/state?node_id=HolyGrail"

q() { psql "$DB" -X -A -t -c "$1" 2>/dev/null; }

if ! psql "$DB" -X -A -t -c "SELECT 1" >/dev/null 2>&1; then
  echo "[cluster-watch] ERROR: Postgres unreachable — cannot determine cluster state"
  exit 2
fi

# Closed legs of THIS signal: same strategy, same entry price, today.
CLOSED=$(q "
  SELECT account_name || ' qty=' || qty || ' exit=' || COALESCE(exit_price::text,'?')
         || ' at ' || to_char(exit_time,'HH24:MI') || ' signal=' || COALESCE(exit_signal,'NULL')
         || ' pnl=' || COALESCE(pnl_dollars::text,'?')
  FROM trades
  WHERE strategy_name='H137_BilateralBreakout'
    AND entry_price = ${ENTRY}
    AND entry_time::date = (NOW() AT TIME ZONE 'America/Chicago')::date
    AND exit_time IS NOT NULL
  ORDER BY exit_time;")

BARE_CLOSE=$(q "
  SELECT COUNT(*) FROM trades
  WHERE strategy_name='H137_BilateralBreakout'
    AND entry_price = ${ENTRY}
    AND entry_time::date = (NOW() AT TIME ZONE 'America/Chicago')::date
    AND exit_time IS NOT NULL
    AND exit_signal = 'Close';")

# Still-open legs, from the live relay.
STATE=$(curl -sf --max-time 15 "$NT8_URL" 2>/dev/null || echo "")
if [ -z "$STATE" ]; then
  echo "[cluster-watch] ERROR: NT8 relay unreachable — open-leg count UNKNOWN (not zero)"
  OPEN="UNKNOWN"; CONTRACTS="UNKNOWN"
else
  read -r OPEN CONTRACTS <<<"$(printf '%s' "$STATE" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin,strict=False)
    p=[x for x in d.get('positions',[]) if str(x.get('entry_price'))=='${ENTRY}']
    print(len(p), sum(x.get('quantity',0) for x in p))
except Exception:
    print('UNKNOWN','UNKNOWN')
")"
fi

echo "[cluster-watch] $(date -u +%Y-%m-%dT%H:%M:%SZ)  open_legs=${OPEN} contracts=${CONTRACTS} closed_legs=$(printf '%s' "$CLOSED" | grep -c . ) bare_Close_exits=${BARE_CLOSE:-?}"
[ -n "$CLOSED" ] && printf '%s\n' "$CLOSED" | sed 's/^/  CLOSED: /'

if [ "$OPEN" = "0" ]; then
  echo "[cluster-watch] CLUSTER FLAT — all legs closed. This watch can be retired."
fi
exit 0
