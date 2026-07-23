#!/usr/bin/env bash
# h137-premarket-check.sh — All-strategy pre-market health check
# Fires at 13:15 UTC (08:15 CT) — 75-min window before H137 signal opens (09:30 ET).
# Checks ALL strategy_states rows with state='Active' seen within 7 days.
# Telegram to Chris gated on: pilot-account P0 (always) OR CT hour >= 08:00.
# DRYRUN=1: print findings, skip all sends (safe for testing).
DRYRUN="${DRYRUN:-0}"
cortextos bus update-cron-fire h137-premarket-check --interval 24h 2>/dev/null || true

DOW=$(date +%u)
if [[ $DOW -ge 6 ]]; then echo "[premarket-check] MARKET CLOSED (weekend) — $(date +'%A')"; exit 0; fi
set -u

DB="postgresql://orbfutures:orbfutures@127.0.0.1/orbfutures_dashboard"
CT_TIME=$(TZ=America/Chicago date '+%I:%M %p CT')
CT_HOUR=$(( 10#$(TZ=America/Chicago date '+%H') ))
BOT_TOKEN="8649138124:AAE2C5QfE2mSCgtHDo_ggveXKfmUvdA1hdo"
CHAT_ID="6585156851"
PILOT_ACCOUNT="PAAPEX4333770000017"
PILOT_STRATEGY="H137_BilateralBreakout"

send_telegram() {
  local msg="$1"
  if [[ "$DRYRUN" == "1" ]]; then
    echo "[premarket-check] DRYRUN — would send Telegram: ${msg:0:80}..."
    return
  fi
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${msg}" > /dev/null 2>&1 || true
}

psql_q() { psql "$DB" -X -A -t -q -c "$1" 2>/dev/null; }

if ! psql "$DB" -X -A -t -q -c "SELECT 1" >/dev/null 2>&1; then
  echo "[premarket-check] ERROR: cannot connect to DB"
  exit 0
fi

# Check pilot account first — P0 if stale/absent
PILOT_AGE=$(psql_q "
  SELECT ROUND(EXTRACT(EPOCH FROM (NOW() - last_seen)) / 60)::int
  FROM strategy_states
  WHERE account_name='${PILOT_ACCOUNT}' AND strategy_name='${PILOT_STRATEGY}'
  ORDER BY last_seen DESC LIMIT 1;")
PILOT_P0=0
if [ -z "$PILOT_AGE" ] || [ "${PILOT_AGE:-0}" -gt 120 ]; then
  PILOT_P0=1
fi

# ACTIVE ROSTER: strategies seen within 48h = expected to run today.
# Rows stale >2h within that window are real alerts (recently broken).
# Zombie rows (>134h stale) are logged separately — never in the alert.
STALE_ROWS=$(psql_q "
  SELECT account_name, strategy_name,
         ROUND(EXTRACT(EPOCH FROM (NOW() - last_seen)) / 3600.0, 1)::text AS age_h
  FROM strategy_states
  WHERE state = 'Active'
    AND last_seen > NOW() - INTERVAL '48 hours'
    AND last_seen < NOW() - INTERVAL '2 hours'
  ORDER BY last_seen DESC;
")

# Zombie rows: Active but unseen for >134h — weekly cleanup candidates, not alerts.
ZOMBIE_COUNT=$(psql_q "
  SELECT COUNT(*) FROM strategy_states
  WHERE state = 'Active'
    AND last_seen < NOW() - INTERVAL '134 hours';
")

# Count fresh active strategies for OK log
ACTIVE_FRESH=$(psql_q "
  SELECT COUNT(*) FROM strategy_states
  WHERE state = 'Active'
    AND last_seen >= NOW() - INTERVAL '2 hours';
")

ZOMBIE_NOTE=""
if [ "${ZOMBIE_COUNT:-0}" -gt 0 ]; then
  ZOMBIE_NOTE=" (${ZOMBIE_COUNT} zombie rows >134h excluded — weekly cleanup)"
fi

if [ -z "$STALE_ROWS" ]; then
  echo "[premarket-check] OK: ${ACTIVE_FRESH} active strategies fresh${ZOMBIE_NOTE} (${CT_TIME})"
  cortextos bus log-event action premarket_check_ok info \
    --meta "{\"fresh_count\":${ACTIVE_FRESH:-0},\"zombie_count\":${ZOMBIE_COUNT:-0}}" 2>/dev/null || true
  exit 0
fi

# Build stale list (active-roster only)
STALE_LIST=""
STALE_COUNT=0
while IFS='|' read -r acct strat age_h; do
  [ -z "$acct" ] && continue
  STALE_LIST="${STALE_LIST}  ${strat} / ${acct}: ${age_h}h stale"$'\n'
  STALE_COUNT=$((STALE_COUNT + 1))
done <<< "$STALE_ROWS"

MSG="PRE-MARKET RED (${CT_TIME}): ${STALE_COUNT} ACTIVE strategies stale >2h (NT8 offline or DLL failure):
${STALE_LIST}Verify NT8 on HolyGrail before H137 window opens 9:30 ET.${ZOMBIE_NOTE}"

echo "[premarket-check] RED: ${STALE_COUNT} stale strategies${ZOMBIE_NOTE}"
echo "$STALE_LIST"

if [[ "$DRYRUN" != "1" ]]; then
  cortextos bus send-message fable-reviewer urgent "$MSG" 2>/dev/null || true
  cortextos bus send-message chief urgent "$MSG" 2>/dev/null || true
fi

# Telegram to Chris — three-case gate:
# 1. PILOT_P0=1 → always send (live-capital exception, any hour)
# 2. PILOT_P0=0 AND CT_HOUR < 9 → NO Chris ping (quiet hours end 09:00 CT); route stale list to agents only
# 3. PILOT_P0=0 AND CT_HOUR >= 9 → send to Chris
if [[ "$PILOT_P0" == "1" ]]; then
  send_telegram "$MSG"
elif [[ "$CT_HOUR" -ge 9 ]]; then
  send_telegram "$MSG"
else
  echo "[premarket-check] Quiet hours (${CT_TIME}, pilot not P0) — Chris Telegram suppressed. Stale list routed to agents only."
fi

# Severity: pilot P0 = critical (live capital at risk); non-pilot stale = warning (informational)
if [[ "$PILOT_P0" == "1" ]]; then
  SEV="critical"
else
  SEV="warning"
fi
cortextos bus log-event error premarket_stale_strategies "$SEV" \
  --meta "{\"stale_count\":${STALE_COUNT},\"fresh_count\":${ACTIVE_FRESH:-0},\"zombie_count\":${ZOMBIE_COUNT:-0},\"pilot_p0\":${PILOT_P0}}" 2>/dev/null || true
