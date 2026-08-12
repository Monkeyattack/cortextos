#!/usr/bin/env bash
# nt8-pipeline-check.sh — Pre-market NT8 data pipeline health check
# Fires at 12:00 UTC (Mon-Fri) before pre-market window (12:45 UTC).
#
# Per-account/per-strategy staleness. The old version took MAX(last_seen) across
# the whole strategy_states table, so one fresh account masked every stale one
# (2026-07-24 P1: PPNTF100024895000002/MarketOpenFlip 42h stale, check said OK
# because PAAPEX4333770000017/H137 had updated 30s earlier).
#
# A row alerts when ALL of:
#   - its account has a heartbeat < STALE_THRESHOLD_HOURS old (monitor is up, so
#     a missing state upload is a real pipeline fault, not an offline VPS)
#   - state is not Archived / Finalized (terminal — legitimately stops reporting)
#   - last_seen is older than STALE_THRESHOLD_HOURS
#   - last_seen is newer than DETACHED_AFTER_DAYS (older = strategy unloaded from
#     NT8 and never tombstoned, a separate backlog defect — counted, not alerted)

set -euo pipefail

DB="postgresql://orbfutures:orbfutures@127.0.0.1/orbfutures_dashboard"
# Credentials come from the devops agent .env, never from this file. They were
# hardcoded here in plaintext until 2026-08-12; treat the old token as exposed.
# Fail-closed: no token means no alerting, so the check must not run at all.
DEVOPS_ENV_FILE="${DEVOPS_ENV_FILE:-/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/devops/.env}"
read_env_value() {
  local key="$1" file="$2"
  [[ -r "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n 1 | tr -d '\042\047'
}
BOT_TOKEN="${BOT_TOKEN:-$(read_env_value BOT_TOKEN "$DEVOPS_ENV_FILE" || true)}"
CHAT_ID="${CHAT_ID:-$(read_env_value CHAT_ID "$DEVOPS_ENV_FILE" || true)}"
if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" ]]; then
  echo "[nt8-pipeline-check] FATAL: BOT_TOKEN/CHAT_ID not readable from ${DEVOPS_ENV_FILE} — refusing to run a check that cannot alert" >&2
  exit 1
fi
STALE_THRESHOLD_HOURS=2
DETACHED_AFTER_DAYS=7

CT_TIME=$(TZ=America/Chicago date '+%I:%M %p CT')

# DRY_RUN=1 prints the Telegram body instead of sending it (for testing).
DRY_RUN="${DRY_RUN:-0}"

send_telegram() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[nt8-check] DRY_RUN telegram:\n%s\n' "$1"
    return
  fi
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    --data-urlencode "text=$1" > /dev/null
}

# --- 1. Table empty? -------------------------------------------------------
ROW_COUNT=$(psql "$DB" -tA -c "SELECT count(*) FROM strategy_states;" 2>/dev/null || echo "")

if [[ -z "$ROW_COUNT" ]]; then
  echo "[nt8-check] ERROR: cannot query strategy_states"
  cortextos bus log-event error nt8_pipeline_query_failed critical --meta '{"reason":"psql_failed"}' 2>/dev/null || true
  exit 1
fi

if (( ROW_COUNT == 0 )); then
  send_telegram "⚠️ NT8 Pipeline ALERT ($CT_TIME): strategy_states table is EMPTY — no data from NT8 VPS at all. Check NinjaTrader + MonkeyAttackMonitor on NT8 Windows VPS."
  echo "[nt8-check] ALERT: strategy_states empty"
  cortextos bus log-event error nt8_pipeline_empty critical --meta '{"row_count":0}' 2>/dev/null || true
  exit 0
fi

# --- 2. Per-row staleness, gated on a live heartbeat for that account ------
STALE_ROWS=$(psql "$DB" -tA -F'|' -c "
  SELECT s.account_name,
         s.strategy_name,
         s.state,
         round(EXTRACT(EPOCH FROM (now() - s.last_seen)) / 3600, 1)
  FROM strategy_states s
  WHERE s.state NOT IN ('Archived', 'Finalized')
    AND s.account_name NOT IN (
      'PPNTETL25024895000005',
      'PPNTETL25024895000006',
      'PPNTETL25024895000007',
      'PAAPEX4333770000002',
      'TAKEPROFITPRO392542906',
      'PPNTPPX50024895000001',
      'TDFYG50201122518'
    )
    AND s.last_seen < now() - interval '${STALE_THRESHOLD_HOURS} hours'
    AND s.last_seen > now() - interval '${DETACHED_AFTER_DAYS} days'
    AND EXISTS (
      SELECT 1 FROM heartbeats h
      WHERE h.account_name = s.account_name
        AND h.timestamp > now() - interval '${STALE_THRESHOLD_HOURS} hours'
    )
  ORDER BY s.last_seen ASC;" 2>/dev/null)

# Rows stale beyond the detached cutoff: strategies unloaded from NT8 that were
# never tombstoned. Reported for context only — not a pipeline fault.
DETACHED_COUNT=$(psql "$DB" -tA -c "
  SELECT count(*) FROM strategy_states s
  WHERE s.state NOT IN ('Archived', 'Finalized')
    AND s.last_seen <= now() - interval '${DETACHED_AFTER_DAYS} days';" 2>/dev/null || echo 0)

FRESH_COUNT=$(psql "$DB" -tA -c "
  SELECT count(*) FROM strategy_states
  WHERE last_seen > now() - interval '${STALE_THRESHOLD_HOURS} hours';" 2>/dev/null || echo 0)

# --- 3. Nothing fresh anywhere = pipeline down ----------------------------
if (( FRESH_COUNT == 0 )); then
  send_telegram "⚠️ NT8 Pipeline STALE ($CT_TIME): ZERO strategy_states rows updated in the last ${STALE_THRESHOLD_HOURS}h across the whole fleet. MonkeyAttackMonitor likely stopped on the NT8 Windows VPS — check NinjaTrader before pre-market open."
  echo "[nt8-check] ALERT: no fresh rows fleet-wide"
  cortextos bus log-event error nt8_pipeline_stale critical --meta '{"fresh_rows":0}' 2>/dev/null || true
  exit 0
fi

# --- 4. Per-account/strategy alert ----------------------------------------
if [[ -n "$STALE_ROWS" ]]; then
  STALE_COUNT=$(printf '%s\n' "$STALE_ROWS" | wc -l)

  DETAIL=""
  while IFS='|' read -r acct strat state age_h; do
    [[ -z "$acct" ]] && continue
    DETAIL+="• ${acct} / ${strat} (${state}) — ${age_h}h stale"$'\n'
    echo "[nt8-check] STALE: ${acct}/${strat} ${state} ${age_h}h"
  done < <(printf '%s\n' "$STALE_ROWS" | head -10)

  if (( STALE_COUNT > 10 )); then
    DETAIL+="…and $(( STALE_COUNT - 10 )) more"$'\n'
  fi

  MSG="⚠️ NT8 Pipeline STALE ($CT_TIME): ${STALE_COUNT} strategy/account state(s) not updated in >${STALE_THRESHOLD_HOURS}h while their account heartbeat is live — states are not reaching the DB.

${DETAIL}
Check the strategy is still loaded + enabled in NinjaTrader on the NT8 Windows VPS before pre-market open."
  send_telegram "$MSG"

  # JSON array of stale rows for the event log
  META_ROWS=$(printf '%s\n' "$STALE_ROWS" | awk -F'|' 'NF>=4 {printf "%s{\"account\":\"%s\",\"strategy\":\"%s\",\"state\":\"%s\",\"age_hours\":%s}", (NR>1?",":""), $1, $2, $3, $4}')
  echo "[nt8-check] ALERT: ${STALE_COUNT} stale account/strategy rows (fresh=${FRESH_COUNT}, detached>${DETACHED_AFTER_DAYS}d=${DETACHED_COUNT})"
  cortextos bus log-event error nt8_pipeline_stale warning \
    --meta "{\"stale_count\":${STALE_COUNT},\"fresh_count\":${FRESH_COUNT},\"detached_count\":${DETACHED_COUNT},\"stale_rows\":[${META_ROWS}]}" 2>/dev/null || true
else
  echo "[nt8-check] OK: ${FRESH_COUNT} strategy_states rows fresh (<${STALE_THRESHOLD_HOURS}h), 0 stale on live-heartbeat accounts, ${DETACHED_COUNT} detached (>${DETACHED_AFTER_DAYS}d, not alerted)"
  cortextos bus log-event action nt8_pipeline_check info \
    --meta "{\"stale_count\":0,\"fresh_count\":${FRESH_COUNT},\"detached_count\":${DETACHED_COUNT}}" 2>/dev/null || true
fi
