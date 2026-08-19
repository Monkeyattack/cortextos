#!/usr/bin/env bash
# nt8-price-monitor.sh — Alert when NT8 BrainExecutor sends close=0 for MCL_ACCOUNT_1
# Runs every 5 minutes via cron. Silent during CME MCL maintenance (4-5 PM CT / 21-22 UTC Mon-Fri).
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
ACCOUNT="MCL_ACCOUNT_1"
LATCH_FILE="/home/claude-dev/.cortextos/default/state/nt8-price-monitor.latch"
ENV_FILE="/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/devops/.env"
CHAT_ID="6585156851"
POLL_SAMPLE=10   # examine last N polls
CURL_TIMEOUT=15

# ---------------------------------------------------------------------------
# Load BOT_TOKEN
# ---------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE" >&2
  exit 1
fi

BOT_TOKEN=$(grep -E '^BOT_TOKEN=' "$ENV_FILE" | head -1 | cut -d'=' -f2- | tr -d '[:space:]')
if [[ -z "$BOT_TOKEN" ]]; then
  echo "ERROR: BOT_TOKEN missing or empty in $ENV_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# CT time helpers
# ---------------------------------------------------------------------------
export TZ=America/Chicago
CT_HOUR=$(date +%-H)     # 0-23
CT_DOW=$(date +%u)       # 1=Mon … 7=Sun
CT_TIME_LABEL=$(date +'%l:%M %p %Z')   # e.g. " 4:32 PM CT"
CT_TIME_LABEL="${CT_TIME_LABEL# }"       # strip leading space (date %l pads with space)

# CME MCL maintenance: 4:00 PM – 5:00 PM CT, Mon–Fri
in_maintenance_window() {
  # CT_DOW 1-5 = Mon-Fri; CT_HOUR 16 = 4 PM, 17 is excluded (window ends at 5 PM)
  if [[ "$CT_DOW" -ge 1 && "$CT_DOW" -le 5 && "$CT_HOUR" -eq 16 ]]; then
    return 0
  fi
  return 1
}

# CME MCL market closed: Fri 4 PM CT → Sun 5 PM CT
# CT_DOW: 1=Mon … 5=Fri, 6=Sat, 7=Sun
in_market_closed_window() {
  # Saturday all day
  if [[ "$CT_DOW" -eq 6 ]]; then return 0; fi
  # Sunday before 5 PM CT (hour < 17)
  if [[ "$CT_DOW" -eq 7 && "$CT_HOUR" -lt 17 ]]; then return 0; fi
  # Friday at or after 4 PM CT (hour >= 16) — maintenance window handles 16 exactly,
  # but post-maintenance (17+) is still closed until Sunday
  if [[ "$CT_DOW" -eq 5 && "$CT_HOUR" -ge 17 ]]; then return 0; fi
  return 1
}

# ---------------------------------------------------------------------------
# Telegram helper
# ---------------------------------------------------------------------------
send_telegram() {
  local msg="$1"
  curl -s --max-time "$CURL_TIMEOUT" \
    -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode "text=${msg}" \
    -o /dev/null
}

# ---------------------------------------------------------------------------
# Ensure latch directory exists
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LATCH_FILE")"

# ---------------------------------------------------------------------------
# Pull recent brain-api logs and extract close= values for the target account
# ---------------------------------------------------------------------------
# Logs contain lines like:
#   GET /api/brain/commands?account=MCL_ACCOUNT_1&...&close=71.5100&...
RAW_LOG=$(pm2 logs brain-api --lines 100 --nostream 2>/dev/null || true)

# Extract the last $POLL_SAMPLE close= values from MCL_ACCOUNT_1 poll lines
mapfile -t CLOSE_VALUES < <(
  echo "$RAW_LOG" \
  | grep -oP "account=${ACCOUNT}[^\"]*close=\K[0-9]+\.[0-9]+" \
  | tail -n "$POLL_SAMPLE"
)

SAMPLE_COUNT="${#CLOSE_VALUES[@]}"

# Not enough data yet — exit quietly
if [[ "$SAMPLE_COUNT" -lt "$POLL_SAMPLE" ]]; then
  echo "INFO: Only $SAMPLE_COUNT polls found for $ACCOUNT (need $POLL_SAMPLE). Skipping." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Evaluate: are all sampled close values zero?
# ---------------------------------------------------------------------------
all_zero=true
last_nonzero=""
for val in "${CLOSE_VALUES[@]}"; do
  # Treat 0.0000 (any number of decimal places of pure zeros) as zero
  if [[ "$val" =~ ^0+\.0+$ ]]; then
    : # still zero
  else
    all_zero=false
    last_nonzero="$val"
  fi
done

# ---------------------------------------------------------------------------
# Recovery path: prices are back
# ---------------------------------------------------------------------------
if [[ "$all_zero" == false ]]; then
  if [[ -f "$LATCH_FILE" ]]; then
    # Was alerted — now recovered
    rm -f "$LATCH_FILE"
    LATEST_CLOSE="${CLOSE_VALUES[-1]}"
    send_telegram "✅ NT8 price feed restored — MCL close=${LATEST_CLOSE}"
    echo "INFO: Recovery detected. Latch cleared. close=${LATEST_CLOSE}"
  else
    echo "INFO: Prices normal (last=${CLOSE_VALUES[-1]}). No latch. Nothing to do."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# All 10 polls are zero
# ---------------------------------------------------------------------------

# Check maintenance window
if in_maintenance_window; then
  echo "INFO: close=0 but within CME maintenance window (4-5 PM CT). Silent."
  exit 0
fi

# Check weekend market closure (Fri 5 PM CT → Sun 5 PM CT)
if in_market_closed_window; then
  echo "INFO: close=0 but market closed for weekend (Fri 4 PM CT – Sun 5 PM CT). Silent."
  exit 0
fi

# Check latch — already alerted for this outage?
if [[ -f "$LATCH_FILE" ]]; then
  echo "INFO: close=0 but latch active (already alerted). Skipping duplicate."
  exit 0
fi

# First detection — set latch and alert
date -u > "$LATCH_FILE"

send_telegram "⚠️ NT8 price feed down — MCL close=0.00 for last ${POLL_SAMPLE} polls (${CT_TIME_LABEL}). Check NT8 connection."
echo "INFO: Zero-price alert sent and latch set."

# ---------------------------------------------------------------------------
# HOW TO INSTALL
# ---------------------------------------------------------------------------
# Register as a CronCreate one-shot or recurring cron via the devops agent.
#
# Run the following CronCreate command (every 5 minutes, Mon-Fri):
#
#   cortextos bus create-cron \
#     --name "nt8-price-monitor" \
#     --schedule "*/5 * * * 1-5" \
#     --command "/home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/nt8-price-monitor.sh" \
#     --agent devops
#
# Or via the agent's config.json crons block, add:
#   {
#     "name": "nt8-price-monitor",
#     "schedule": "*/5 * * * 1-5",
#     "command": "/home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/nt8-price-monitor.sh"
#   }
#
# Note: schedule "*/5 * * * 1-5" = every 5 minutes, Mon–Fri UTC.
# The maintenance window check is handled inside the script itself.
# ---------------------------------------------------------------------------
