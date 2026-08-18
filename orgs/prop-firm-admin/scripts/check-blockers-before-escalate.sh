#!/usr/bin/env bash
# check-blockers-before-escalate.sh
# Run this BEFORE any urgent escalation (send-message urgent OR send-telegram for incidents).
# If the fetch fails for any reason, exit 1 — cannot-check is not permission to send.
# Prints ALL live blockers unfiltered. A human scanning 8 lines spots duplicates;
# a regex filter silently passes when it misses — that's the failure mode this prevents.
set -uo pipefail

PM_API_KEY="${PM_API_KEY:-}"
if [ -z "$PM_API_KEY" ]; then
  PM_API_KEY=$(grep PM_API_KEY /home/claude-dev/repos/pm-system/.env 2>/dev/null | cut -d= -f2 | tr -d '"')
fi

if [ -z "$PM_API_KEY" ]; then
  echo "[check-blockers] BLOCKED: PM_API_KEY not set — cannot fetch blockers, cannot escalate" >&2
  exit 1
fi

response=$(curl -sf --max-time 10 "https://pm.profithits.app/api/blockers" \
  -H "x-api-key: $PM_API_KEY" 2>/dev/null)
rc=$?

if [ $rc -ne 0 ] || [ -z "$response" ]; then
  echo "[check-blockers] BLOCKED: fetch failed (rc=$rc) — cannot confirm no duplicate in-flight, cannot escalate" >&2
  exit 1
fi

count=$(printf '%s' "$response" | python3 -c "import json,sys; bs=json.load(sys.stdin); print(len(bs))" 2>/dev/null)
if [ -z "$count" ]; then
  echo "[check-blockers] BLOCKED: response parse failed — cannot confirm no duplicate, cannot escalate" >&2
  exit 1
fi

echo "[check-blockers] $count live blocker(s) — review before escalating:"
printf '%s' "$response" | python3 -c "
import json,sys
for i,b in enumerate(json.load(sys.stdin),1):
    print(f'  {i}. [{b.get(\"id\",\"?\")}] {b.get(\"title\",\"?\")[:80]}')
" 2>/dev/null

exit 0
