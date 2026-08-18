#!/usr/bin/env bash
# quota-tripwire-watchdog.sh — A9: weekly liveness check for the tripwire itself.
# Verifies the tripwire timer is ACTIVE and has fired recently, then sends a
# status message: "ACTIVE" if healthy, "⚠️ DOWN" if the timer is dead or stale.
# Silence from this script means the WATCHDOG is down — not the tripwire.

set -euo pipefail

ENV_FILE="/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/devops/.env"
CHAT_ID="6585156851"
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR

# Max age for tripwire last-run before we consider it stale (2x 30min interval)
MAX_STALE_MINS=60

BOT_TOKEN=""
[[ -f "$ENV_FILE" ]] && BOT_TOKEN=$(grep -m1 '^BOT_TOKEN=' "$ENV_FILE" | cut -d'=' -f2- || true)
if [[ -z "$BOT_TOKEN" ]]; then
  echo "ERROR: BOT_TOKEN not found in $ENV_FILE" >&2
  exit 1
fi

send_telegram() {
  curl -s --max-time 15 -X POST \
      "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${1}" \
      > /dev/null 2>&1
}

# Check 1: is the systemd timer unit active?
TIMER_STATE=$(systemctl --user is-active quota-tripwire.timer 2>/dev/null || echo "inactive")

# Check 2: when did the tripwire service last run? (via systemctl status)
LAST_RUN_MINS=9999
if [[ "$TIMER_STATE" == "active" ]]; then
  LAST_RUN_ISO=$(systemctl --user show quota-tripwire.service \
    --property=ExecMainStartTimestamp --value 2>/dev/null || true)
  if [[ -n "$LAST_RUN_ISO" && "$LAST_RUN_ISO" != "n/a" ]]; then
    LAST_RUN_EPOCH=$(date -d "$LAST_RUN_ISO" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    LAST_RUN_MINS=$(( (NOW_EPOCH - LAST_RUN_EPOCH) / 60 ))
  fi
fi

# Verdict
if [[ "$TIMER_STATE" == "active" ]] && (( LAST_RUN_MINS <= MAX_STALE_MINS )); then
  MSG="[tripwire-watchdog] quota-tripwire ACTIVE — timer running, last fired ${LAST_RUN_MINS}m ago. Next watchdog ping: ~7d."
  send_telegram "$MSG"
  echo "ACTIVE: timer=${TIMER_STATE}, last_run=${LAST_RUN_MINS}m ago"
else
  if [[ "$TIMER_STATE" != "active" ]]; then
    REASON="timer state=${TIMER_STATE}"
  else
    REASON="last fired ${LAST_RUN_MINS}m ago (>${MAX_STALE_MINS}m stale threshold)"
  fi
  MSG="⚠️ [tripwire-watchdog] quota-tripwire DOWN — ${REASON}. Fleet quota exhaustion may go undetected. Manual check required: XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user status quota-tripwire.timer"
  send_telegram "$MSG"
  echo "DOWN: ${REASON}" >&2
  exit 1
fi
