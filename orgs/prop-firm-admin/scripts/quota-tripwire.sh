#!/usr/bin/env bash
# quota-tripwire.sh — Layer 1 quota-exhaustion sidecar
# Fires a raw bot-API Telegram to Chris when >=60% of ACTIVE fleet agents
# simultaneously exceed their own staleness bound.
# Runs from systemd user timer (independent of daemon). Zero LLM dependency.
#
# Bounds use OBSERVED heartbeat cadence (~1h for most, ~4h for workspace),
# not cron interval — detects quota exhaustion within ~2h of onset.
#
# Latch: /tmp/.quota-tripwire-latch — prevents notification storms.
# Recovery: on next run where <60% stale, sends one "fleet recovered" message.
#
# Exempt (omitted): fanboy, deep, architect (on-demand critics),
# statler/waldorf (bus-only critics), polymarket (decommissioned),
# render-monitor (heartbeat-stamp only, no session heartbeat).

set -euo pipefail

HEARTBEAT_DIR="/home/claude-dev/.cortextos/default/state"
ENV_FILE="/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/devops/.env"
LATCH_FILE="/tmp/.quota-tripwire-latch"
CHAT_ID="6585156851"
TRIP_THRESHOLD_PCT=60

# BOT_TOKEN: read from agent .env — never hardcoded
BOT_TOKEN=""
[[ -f "$ENV_FILE" ]] && BOT_TOKEN=$(grep -m1 '^BOT_TOKEN=' "$ENV_FILE" | cut -d'=' -f2- || true)
if [[ -z "$BOT_TOKEN" ]]; then
  echo "ERROR: BOT_TOKEN not found in $ENV_FILE" >&2
  exit 1
fi

# ── Agent → staleness bound (hours), derived from OBSERVED stamp cadence.
# Most agents stamp within ~1h; stale_bound = 2x observed = 2h.
# workspace stamps ~4h; stale_bound = 2x = 8h.
# Keys match filesystem directory names; explicit overrides for hyphenated dirs.
declare -A STALE_BOUNDS
STALE_BOUNDS[chief]=2
STALE_BOUNDS[analyst]=2
STALE_BOUNDS[devops]=2
STALE_BOUNDS[accounts]=2
STALE_BOUNDS[notes]=2
STALE_BOUNDS[pm]=2
STALE_BOUNDS[health]=2
STALE_BOUNDS[fable_reviewer]=2    # dir = fable-reviewer
STALE_BOUNDS[lit_agent]=2         # dir = lit_agent
STALE_BOUNDS[ma_studio_agency]=2  # dir = ma_studio_agency
STALE_BOUNDS[ma_studio_room]=2    # dir = ma_studio_room
STALE_BOUNDS[ma_studio_wit]=2     # dir = ma_studio_wit
STALE_BOUNDS[media]=2
STALE_BOUNDS[pmo]=2
STALE_BOUNDS[project_manager]=2   # dir = project-manager
STALE_BOUNDS[reserve]=2
STALE_BOUNDS[site_manager]=2      # dir = site_manager
STALE_BOUNDS[writer]=2
STALE_BOUNDS[writer_amazonians]=2 # dir = writer_amazonians
STALE_BOUNDS[writer_pirate]=2     # dir = writer_pirate
STALE_BOUNDS[workspace]=8         # observed ~4h cadence; 2x = 8h

# Explicit directory name overrides for keys whose fs path uses hyphens
declare -A AGENT_DIRS
AGENT_DIRS[fable_reviewer]="fable-reviewer"
AGENT_DIRS[project_manager]="project-manager"

NOW=$(date +%s)
STALE_COUNT=0
TOTAL_COUNT=0
STALE_AGENTS=()

for agent_key in "${!STALE_BOUNDS[@]}"; do
    stale_bound_h="${STALE_BOUNDS[$agent_key]}"
    stale_bound_s=$(( stale_bound_h * 3600 ))

    if [[ -n "${AGENT_DIRS[$agent_key]+x}" ]]; then
        agent_dir="${AGENT_DIRS[$agent_key]}"
    else
        agent_dir="$agent_key"
    fi

    hb_file="${HEARTBEAT_DIR}/${agent_dir}/heartbeat.json"
    TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))

    if [[ ! -f "$hb_file" ]]; then
        STALE_COUNT=$(( STALE_COUNT + 1 ))
        STALE_AGENTS+=("${agent_dir}(no-file)")
        continue
    fi

    last_hb_ts=$(python3 -c "
import json, sys
d = json.load(open('${hb_file}'))
ts = d.get('last_heartbeat', '')
if ts:
    import datetime
    dt = datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
    print(int(dt.timestamp()))
else:
    print(0)
" 2>/dev/null || echo 0)

    age_s=$(( NOW - last_hb_ts ))
    if (( age_s > stale_bound_s )); then
        STALE_COUNT=$(( STALE_COUNT + 1 ))
        age_h=$(( age_s / 3600 ))
        STALE_AGENTS+=("${agent_dir}(${age_h}h)")
    fi
done

if (( TOTAL_COUNT == 0 )); then exit 0; fi
PCT=$(( (STALE_COUNT * 100) / TOTAL_COUNT ))

TRIPPED=false
if (( PCT >= TRIP_THRESHOLD_PCT )); then TRIPPED=true; fi

send_telegram() {
    local msg="$1"
    curl -s --max-time 15 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${msg}" \
        -d "parse_mode=Markdown" \
        > /dev/null 2>&1
}

if $TRIPPED; then
    if [[ ! -f "$LATCH_FILE" ]]; then
        touch "$LATCH_FILE"
        AGENTS_LIST=$(IFS=','; echo "${STALE_AGENTS[*]}" | head -c 300)
        MSG="🚨 *QUOTA TRIPWIRE* — ${STALE_COUNT}/${TOTAL_COUNT} fleet agents stale (${PCT}%). Likely quota exhaustion. No LLM calls available. Stale: ${AGENTS_LIST}"
        send_telegram "$MSG"
    fi
else
    if [[ -f "$LATCH_FILE" ]]; then
        rm -f "$LATCH_FILE"
        MSG="✅ *QUOTA TRIPWIRE CLEARED* — Fleet recovered. ${STALE_COUNT}/${TOTAL_COUNT} agents stale (${PCT}%), below ${TRIP_THRESHOLD_PCT}% threshold."
        send_telegram "$MSG"
    fi
fi
