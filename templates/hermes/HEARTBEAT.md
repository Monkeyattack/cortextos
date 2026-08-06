# Heartbeat Checklist — EXECUTE EVERY STEP. SKIP NOTHING.

This runs on your heartbeat cron (every 4 hours). Execute EVERY step in order.
Skipping steps = broken system.

## Step 1: Update heartbeat (DO THIS FIRST)

```bash
cortextos bus update-heartbeat "<1-sentence summary of current work>"
```

If this fails, your agent shows as DEAD on the dashboard. Fix it before anything else.

**Note:** `update-heartbeat` (Step 1) and `log-event heartbeat agent_heartbeat` (Step 4) are NOT interchangeable.
- `update-heartbeat` refreshes the dashboard status-string field (what the dashboard reads to know you're alive).
- `log-event heartbeat …` appends to the activity feed (JSONL append-only event log).

Both are required every cycle. Skipping Step 1 leaves your dashboard view stale even though you're firing events.

## Step 2: Telegram channel health probe

```bash
# Locate this agent's .env — skip silently if absent or placeholder token
AGENT_ENV=$(find /home/claude-dev/cortextos/orgs -name ".env" -path "*/${CTX_AGENT_NAME}/.env" 2>/dev/null | head -1)
if [[ -z "$AGENT_ENV" ]] || ! grep -q '^BOT_TOKEN=' "$AGENT_ENV" 2>/dev/null; then
  echo "[heartbeat] Telegram probe: no .env or BOT_TOKEN — skipping"
else
  # shellcheck source=/dev/null
  source "$AGENT_ENV"
  if printf '%s' "${BOT_TOKEN:-}" | grep -qE 'NEEDS_NEW|PLACEHOLDER|CHANGEME|\{\{'; then
    echo "[heartbeat] Telegram probe: placeholder token — skipping"
  else
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" != "200" ]]; then
      cortextos bus log-event heartbeat telegram_channel_down error \
        --meta "{\"http_code\":\"${HTTP_CODE}\",\"agent\":\"${CTX_AGENT_NAME}\"}" 2>/dev/null || true
      echo "[heartbeat] FAIL: Telegram channel down (HTTP ${HTTP_CODE}) — logged"
    else
      echo "[heartbeat] Telegram probe: OK (HTTP 200)"
    fi
    # Token collision check — alarm if BOT_TOKEN is shared by another agent (e.g. copy-paste misconfiguration)
    MY_MD5=$(printf '%s' "$BOT_TOKEN" | md5sum | cut -d' ' -f1)
    COLLIDES=""
    while IFS= read -r other_env; do
      other_token=$(grep -oP '(?<=^BOT_TOKEN=)\S+' "$other_env" 2>/dev/null || true)
      [[ -z "$other_token" ]] && continue
      other_md5=$(printf '%s' "$other_token" | md5sum | cut -d' ' -f1)
      if [[ "$other_md5" == "$MY_MD5" ]]; then
        other_agent=$(basename "$(dirname "$other_env")")
        COLLIDES="${COLLIDES}${other_agent},"
      fi
    done < <(find /home/claude-dev/cortextos/orgs -name ".env" \
      -not -path "*/${CTX_AGENT_NAME}/.env" 2>/dev/null)
    if [[ -n "$COLLIDES" ]]; then
      cortextos bus log-event heartbeat telegram_token_collision error \
        --meta "{\"agent\":\"${CTX_AGENT_NAME}\",\"collides_with\":\"${COLLIDES%,}\"}" 2>/dev/null || true
      echo "[heartbeat] WARN: BOT_TOKEN collision with ${COLLIDES%,} — logged"
    fi
  fi
fi
```

## Step 3: Check inbox

```bash
cortextos bus check-inbox
```

Process ALL messages. ACK every single one:
```bash
cortextos bus ack-inbox "<message_id>"
```

Un-ACK'd messages are re-delivered in 5 minutes.
Target: 0 un-ACK'd messages after this step.

## Step 4: Check task queue

```bash
cortextos bus list-tasks --agent $CTX_AGENT_NAME --status pending
cortextos bus list-tasks --agent $CTX_AGENT_NAME --status in_progress
```

- Pending tasks: pick the highest priority one and start it
- In-progress tasks older than 2 hours: complete them or update status with a note
- No tasks: check GOALS.md for objectives, then check with orchestrator

## Step 5: Log heartbeat event

```bash
cortextos bus log-event heartbeat agent_heartbeat info --meta '{"agent":"'$CTX_AGENT_NAME'"}'
```

## Step 6: Write daily memory

```bash
TODAY=$(date -u +%Y-%m-%d)
mkdir -p memory
cat >> "memory/$TODAY.md" << MEMORY

## Heartbeat Update - $(date -u +%H:%M)
- WORKING ON: <task_id or "none">
- Status: <healthy/working/blocked>
- Inbox: <N messages processed>
- Next action: <what you will do next>
MEMORY
```

## Step 7: Re-index memory to KB

```bash
cortextos bus kb-ingest ./MEMORY.md ./memory/$(date -u +%Y-%m-%d).md \
  --org $CTX_ORG --agent $CTX_AGENT_NAME --scope private --collection memory-$CTX_AGENT_NAME --force
```

## Step 8: Check GOALS.md

Read GOALS.md for any new objectives. If goals changed, create tasks:
```bash
cortextos bus create-task "<title>" --desc "<description>" --assignee $CTX_AGENT_NAME
```

## Step 9: Resume work

Pick your highest priority task and work on it.

```bash
cortextos bus update-task "<task_id>" in_progress
# ... do the work ...
cortextos bus complete-task "<task_id>" "<summary of what was produced>"
```

---

REMINDER: A heartbeat with 0 events logged and 0 memory updates means you did nothing visible.
Target: >= 2 events and >= 1 memory update per heartbeat cycle.
