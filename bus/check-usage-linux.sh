#!/usr/bin/env bash
# Monitor Claude usage by parsing agent stdout logs for the usage warning banner.
# Sends a Telegram alert when any agent crosses the threshold.
# Designed to run as a standalone cron — no agent context required.
#
# Tracks 5-hour and weekly windows SEPARATELY. Reports hours-to-exhaustion
# based on the reset timestamp in the banner. Alerts at --warn threshold
# (default 80%) per window independently.
#
# A6 recovery stagger: when a window resets (usage drops >20%), the recovery
# alert advises holding non-critical agents for 5 min to avoid pile-on.
# Fail-safe-halt agents (chief/analyst/accounts) are called out explicitly.
#
# Usage:
#   check-usage-linux.sh [--warn N] [--chat-id ID] [--token TOKEN] [--instance ID]
#
# Options:
#   --warn N        Alert threshold percentage (default: 80)
#   --chat-id ID    Telegram chat ID
#   --token TOKEN   Telegram bot token (or set BOT_TOKEN env var)
#   --instance ID   cortextos instance (default: default)

set -euo pipefail

WARN_PCT=80
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
ALERT_CACHE_5H="${CACHE_DIR}/linux-alert-5h.txt"
ALERT_CACHE_7D="${CACHE_DIR}/linux-alert-7d.txt"
BURN_CACHE_5H="${CACHE_DIR}/linux-burn-5h.json"
BURN_CACHE_7D="${CACHE_DIR}/linux-burn-7d.json"
mkdir -p "$CACHE_DIR"

# ── Scan all agent logs, track 5h and weekly separately ─────────────────────
MAX_5H_PCT=0; MAX_5H_AGENT=""; MAX_5H_LINE=""
MAX_7D_PCT=0; MAX_7D_AGENT=""; MAX_7D_LINE=""

for log in "${LOGS_DIR}"/*/stdout.log; do
  [[ -f "$log" ]] || continue
  agent=$(basename "$(dirname "$log")")

  # Extract last occurrence of each window type
  line_5h=$(tail -c 500000 "$log" 2>/dev/null | strings | \
    grep -oE "You've used [0-9]+% of your 5-hour limit[^)]*\)" | tail -1 || true)
  line_7d=$(tail -c 500000 "$log" 2>/dev/null | strings | \
    grep -oE "You've used [0-9]+% of your weekly limit[^)]*\)" | tail -1 || true)

  if [[ -n "$line_5h" ]]; then
    pct=$(echo "$line_5h" | grep -oE "[0-9]+" | head -1)
    if [[ -n "$pct" ]] && (( pct > MAX_5H_PCT )); then
      MAX_5H_PCT=$pct; MAX_5H_AGENT=$agent; MAX_5H_LINE=$line_5h
    fi
  fi

  if [[ -n "$line_7d" ]]; then
    pct=$(echo "$line_7d" | grep -oE "[0-9]+" | head -1)
    if [[ -n "$pct" ]] && (( pct > MAX_7D_PCT )); then
      MAX_7D_PCT=$pct; MAX_7D_AGENT=$agent; MAX_7D_LINE=$line_7d
    fi
  fi
done

# ── Hours-to-exhaustion parser ───────────────────────────────────────────────
# Banner: "... resets in Xh Ym)" or "resets in Ym)" or "resets in Xs)"
hours_to_reset() {
  local line="$1"
  local h=0 m=0
  h=$(echo "$line" | grep -oE "([0-9]+)h" | grep -oE "[0-9]+" | head -1 || echo 0)
  m=$(echo "$line" | grep -oE "([0-9]+)m" | grep -oE "[0-9]+" | head -1 || echo 0)
  [[ -z "$h" ]] && h=0
  [[ -z "$m" ]] && m=0
  # Return total minutes, caller converts
  echo $(( h * 60 + m ))
}

fmt_reset() {
  local mins="$1"
  if (( mins <= 0 )); then echo "soon"; return; fi
  local h=$(( mins / 60 ))
  local m=$(( mins % 60 ))
  if (( h > 0 && m > 0 )); then echo "${h}h ${m}m"
  elif (( h > 0 )); then echo "${h}h"
  else echo "${m}m"; fi
}

# ── Output JSON summary ───────────────────────────────────────────────────────
MAX_PCT=$(( MAX_5H_PCT > MAX_7D_PCT ? MAX_5H_PCT : MAX_7D_PCT ))
MAX_AGENT="${MAX_5H_AGENT:-${MAX_7D_AGENT:-}}"
if (( MAX_7D_PCT > MAX_5H_PCT )); then MAX_AGENT="$MAX_7D_AGENT"; fi

if (( MAX_PCT == 0 )); then
  echo '{"status":"ok","max_pct":0,"five_hour":0,"weekly":0,"message":"No usage data found in logs"}'
  exit 0
fi

echo "{\"status\":\"ok\",\"max_pct\":${MAX_PCT},\"five_hour\":${MAX_5H_PCT},\"weekly\":${MAX_7D_PCT},\"agent\":\"${MAX_AGENT}\"}"

# ── Alert helpers ─────────────────────────────────────────────────────────────
send_telegram() {
  local msg="$1"
  if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
    curl -sf "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${CHAT_ID}" \
      --data-urlencode "text=${msg}" \
      >/dev/null 2>&1 || true
  fi
}

# Compute burn-rate projection from cached prior sample.
# Caches {pct, ts} per window; computes Δpct/Δt → projected mins to 100%.
# Returns "Xh Ym to exhaustion" or "" if insufficient data.
burn_rate_forecast() {
  local pct="$1" burn_cache="$2"
  local NOW_S; NOW_S=$(date +%s)

  local forecast=""
  if [[ -f "$burn_cache" ]]; then
    local prev_pct prev_ts
    prev_pct=$(python3 -c "import json; d=json.load(open('$burn_cache')); print(d.get('pct',0))" 2>/dev/null || echo 0)
    prev_ts=$(python3 -c "import json; d=json.load(open('$burn_cache')); print(d.get('ts',0))" 2>/dev/null || echo 0)
    local delta_pct=$(( pct - prev_pct ))
    local delta_s=$(( NOW_S - prev_ts ))
    # Need positive burn (pct increasing) and at least 1 min of history
    if (( delta_pct > 0 && delta_s >= 60 )); then
      # pct_per_min = delta_pct / (delta_s / 60)
      # mins_to_100 = (100 - pct) / pct_per_min
      local mins_to_100
      mins_to_100=$(python3 -c "
delta_pct=$delta_pct; delta_s=$delta_s; pct=$pct
ppm = delta_pct / (delta_s / 60.0)
m = (100 - pct) / ppm if ppm > 0 else 0
print(int(m))
" 2>/dev/null || echo 0)
      if (( mins_to_100 > 0 )); then
        forecast=$(fmt_reset "$mins_to_100")
      fi
    fi
  fi

  # Always update cache with current sample
  python3 -c "import json; f=open('$burn_cache','w'); json.dump({'pct':$pct,'ts':$NOW_S},f)" 2>/dev/null || true
  echo "$forecast"
}

check_and_alert() {
  local pct="$1" agent="$2" line="$3" window="$4" cache_file="$5" burn_cache="$6"
  local last=0
  [[ -f "$cache_file" ]] && last=$(cat "$cache_file" 2>/dev/null || echo 0)

  if (( pct >= WARN_PCT )) && (( pct > last )); then
    local reset_mins; reset_mins=$(hours_to_reset "$line")
    # Guard fragile parse: fall back gracefully if banner format changed
    local reset_label=""
    if (( reset_mins > 0 )); then
      reset_label=$(fmt_reset "$reset_mins")
    fi
    local window_label="$window"

    # Real burn-rate projection (Δpct/Δt between consecutive samples)
    local forecast; forecast=$(burn_rate_forecast "$pct" "$burn_cache")

    local headroom_clause=""
    if [[ -n "$forecast" ]]; then
      headroom_clause=" (~${forecast} to exhaustion at current rate)"
    fi
    local reset_clause=""
    if [[ -n "$reset_label" ]]; then
      reset_clause=" Resets in ${reset_label}."
    fi

    if (( pct >= 95 )); then
      MSG="🚨 CRITICAL (${window_label}): Claude at ${pct}%.${reset_clause}${headroom_clause} HALT: chief/analyst/accounts must NOT fall back."
    elif (( pct >= 85 )); then
      MSG="⚠️ WARNING (${window_label}): Claude at ${pct}% (${agent}).${reset_clause}${headroom_clause}"
    else
      MSG="Heads up (${window_label}): Claude at ${pct}% (${agent}).${reset_clause}${headroom_clause}"
    fi
    send_telegram "$MSG"
    echo "$pct" > "$cache_file"
  else
    # Still update burn cache even when not alerting (maintains rate history)
    burn_rate_forecast "$pct" "$burn_cache" > /dev/null 2>&1 || true
  fi

  # A6 recovery advisory — daemon replays one catch-up fire per missed cron on
  # recovery (confirmed in cron-scheduler.ts). With N crons across 18+ agents,
  # simultaneous catch-up re-exhausts the new window. Advisory tells Chris to
  # let critical agents (chief/analyst/accounts) catch up first; manual hold
  # only. Full daemon-level stagger is a separate L3 task.
  if (( pct < last - 20 && last >= WARN_PCT )); then
    local stagger_msg="✅ Claude ${window_label} quota reset (was ${last}%, now ${pct}%). Daemon will replay one catch-up fire per missed cron — all agents start simultaneously. Manual stagger: let chief/analyst/accounts catch up first; hold other agents 5 min to avoid re-exhausting the new window."
    send_telegram "$stagger_msg"
    echo "0" > "$cache_file"
  fi
}

# ── Per-window independent alerts ────────────────────────────────────────────
(( MAX_5H_PCT > 0 )) && check_and_alert "$MAX_5H_PCT" "$MAX_5H_AGENT" "$MAX_5H_LINE" "5h window" "$ALERT_CACHE_5H" "$BURN_CACHE_5H"
(( MAX_7D_PCT > 0 )) && check_and_alert "$MAX_7D_PCT" "$MAX_7D_AGENT" "$MAX_7D_LINE" "7d window" "$ALERT_CACHE_7D" "$BURN_CACHE_7D"
