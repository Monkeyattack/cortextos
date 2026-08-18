#!/bin/bash
# Stall detector for devops agent (P2, Option B: event log query).
# Checks if agent has processed any non-heartbeat/non-cron events in the last 2h.
# If none found AND it's day mode (09:00–21:00 CT), exits with code 1 + prints warning.
# Usage: bash check-stall.sh [--agent <name>] [--window <minutes>]
# Called from heartbeat or by health agent.

AGENT="${CTX_AGENT_NAME:-devops}"
WINDOW_MINUTES=120  # 2 hours

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2;;
    --window) WINDOW_MINUTES="$2"; shift 2;;
    *) shift;;
  esac
done

# Scan for stale inbox lock directories (>1h old) — fleet hygiene check
LOCK_ROOT="${HOME}/.cortextos/default/inbox"
LOCK_NOW=$(date +%s)
while IFS= read -r -d '' LOCK_DIR; do
  LOCK_MTIME=$(stat -c %Y -- "$LOCK_DIR" 2>/dev/null) || continue
  [[ "$LOCK_MTIME" =~ ^[0-9]+$ ]] || continue
  LOCK_AGE_SECONDS=$(( LOCK_NOW - LOCK_MTIME ))
  (( LOCK_AGE_SECONDS > 3600 )) || continue
  LOCK_AGE_HOURS=$(( LOCK_AGE_SECONDS / 3600 ))
  LOCK_PARENT=${LOCK_DIR%/.lock.d}
  LOCK_AGENT=${LOCK_PARENT##*/}
  LOCK_META=$(python3 -c "import json,sys; print(json.dumps({'agent':sys.argv[1],'age_hours':int(sys.argv[2])},separators=(',',':')))" \
    "$LOCK_AGENT" "$LOCK_AGE_HOURS") || continue
  printf 'stale inbox lock: agent=%s age_hours=%d\n' "$LOCK_AGENT" "$LOCK_AGE_HOURS"
  cortextos bus log-event error stale_inbox_lock warning --meta "$LOCK_META"
done < <(find "$LOCK_ROOT" -type d -name .lock.d -print0 2>/dev/null)

# Check day mode (09:00–21:00 CT)
CT_HOUR=$(TZ=America/Chicago date +%-H)
if [[ $CT_HOUR -lt 9 || $CT_HOUR -ge 21 ]]; then
  echo "stall-check: night mode ($CT_HOUR:xx CT) — skip"
  exit 0
fi

# Query events from last N minutes
SINCE_UTC=$(date -u -d "$WINDOW_MINUTES minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
            date -u -v-${WINDOW_MINUTES}M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

NON_HB_EVENTS=$(cortextos bus list-events --since ${WINDOW_MINUTES}m --format json 2>/dev/null | \
  python3 -c "
import json, sys
events = json.load(sys.stdin)
skip = {'agent_heartbeat', 'heartbeat', 'cron_fire', 'update_cron_fire', 'retro_scan_clean', 'opportunity_scan_clean', 'incident_latency_skip'}
real = [e for e in events if e.get('event','') not in skip and e.get('category','') not in {'heartbeat'}]
print(len(real))
" 2>/dev/null)

if [[ -z "$NON_HB_EVENTS" || "$NON_HB_EVENTS" -eq 0 ]]; then
  # Suppress false positives: if all pending work is [HUMAN]-blocked (waiting on Chris),
  # the agent is legitimately idle — not stalled.
  HUMAN_BLOCKED=$(cortextos bus list-tasks --agent "$AGENT" --status pending --format json 2>/dev/null | \
    python3 -c "
import json, sys
try:
    tasks = json.load(sys.stdin)
except Exception:
    tasks = []
blocked = [t for t in tasks
           if 'HUMAN' in (t.get('title','') or '').upper()
           or 'HUMAN' in (t.get('description','') or '').upper()]
print(len(blocked))
" 2>/dev/null)

  if [[ -n "$HUMAN_BLOCKED" && "$HUMAN_BLOCKED" -ge 1 ]]; then
    echo "stall-check: suppressed — $HUMAN_BLOCKED HUMAN-blocked task(s) in queue"
    exit 0
  fi

  echo "STALL_DETECTED: $AGENT has 0 non-heartbeat events in last ${WINDOW_MINUTES}m during day mode (${CT_HOUR}:xx CT)"
  cortextos bus log-event heartbeat stall_detected warning \
    --meta "{\"agent\":\"$AGENT\",\"window_minutes\":$WINDOW_MINUTES,\"ct_hour\":$CT_HOUR}" 2>/dev/null
  exit 1
else
  echo "stall-check: OK — $NON_HB_EVENTS real events in last ${WINDOW_MINUTES}m"
  exit 0
fi
