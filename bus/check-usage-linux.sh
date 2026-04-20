#!/usr/bin/env bash
# Monitor Claude usage by parsing agent stdout logs for the usage warning banner.
# Sends a Telegram alert when any agent crosses the threshold.
# Designed to run as a standalone cron — no agent context required.
#
# Usage:
#   check-usage-linux.sh [--warn N] [--chat-id ID] [--token TOKEN] [--instance ID]
#
# Options:
#   --warn N        Alert threshold percentage (default: 75)
#   --chat-id ID    Telegram chat ID
#   --token TOKEN   Telegram bot token (or set BOT_TOKEN env var)
#   --instance ID   cortextos instance (default: default)

set -euo pipefail

WARN_PCT=75
CHAT_ID=""
BOT_TOKEN="${BOT_TOKEN:-}"
INSTANCE="default"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --warn)      WARN_PCT="$2";  shift 2 ;;
    --chat-id)   CHAT_ID="$2";   shift 2 ;;
    --token)     BOT_TOKEN="$2"; shift 2 ;;
    --instance)  INSTANCE="$2";  shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

LOGS_DIR="${HOME}/.cortextos/${INSTANCE}/logs"
CACHE_DIR="${HOME}/.cortextos/${INSTANCE}/state/usage"
ALERT_CACHE="${CACHE_DIR}/linux-alert-sent.txt"
mkdir -p "$CACHE_DIR"

# Find highest usage % across all agent stdout logs
# Pattern: "You've used 87% of your weekly limit · resets ..."
MAX_PCT=0
MAX_AGENT=""
MAX_LINE=""

for log in "${LOGS_DIR}"/*/stdout.log; do
  [[ -f "$log" ]] || continue
  agent=$(basename "$(dirname "$log")")

  line=$(tail -c 500000 "$log" 2>/dev/null | strings | grep -oE "You've used [0-9]+% of your (weekly|5-hour) limit[^)]*\)" | tail -1 || true)
  [[ -z "$line" ]] && continue

  pct=$(echo "$line" | grep -oE "[0-9]+" | head -1)
  if [[ -n "$pct" ]] && (( pct > MAX_PCT )); then
    MAX_PCT=$pct
    MAX_AGENT=$agent
    MAX_LINE=$line
  fi
done

if (( MAX_PCT == 0 )); then
  echo '{"status":"ok","max_pct":0,"message":"No usage data found in logs"}'
  exit 0
fi

echo "{\"status\":\"ok\",\"max_pct\":${MAX_PCT},\"agent\":\"${MAX_AGENT}\",\"detail\":\"${MAX_LINE}\"}"

# Check if we already alerted at this level (avoid spam)
LAST_ALERTED=0
[[ -f "$ALERT_CACHE" ]] && LAST_ALERTED=$(cat "$ALERT_CACHE" 2>/dev/null || echo 0)

send_telegram() {
  local msg="$1"
  if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
    curl -sf "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${msg}" \
      >/dev/null 2>&1 || true
  fi
}

if (( MAX_PCT >= WARN_PCT )) && (( MAX_PCT > LAST_ALERTED )); then
  if (( MAX_PCT >= 95 )); then
    MSG="CRITICAL: Claude usage at ${MAX_PCT}% (seen on ${MAX_AGENT}). Agents will pause imminently."
  elif (( MAX_PCT >= 85 )); then
    MSG="WARNING: Claude usage at ${MAX_PCT}% (seen on ${MAX_AGENT}). Getting close to the limit."
  else
    MSG="Heads up: Claude usage at ${MAX_PCT}% (${MAX_AGENT}). ${MAX_LINE}"
  fi
  send_telegram "$MSG"
  echo "$MAX_PCT" > "$ALERT_CACHE"
fi

# Reset cache if usage dropped significantly (new window)
if (( MAX_PCT < LAST_ALERTED - 20 )); then
  echo "0" > "$ALERT_CACHE"
fi
