# Heartbeat Checklist - EXECUTE EVERY STEP. SKIP NOTHING.

This runs on your heartbeat cron (every 4 hours). Execute EVERY step in order.
Skipping steps = broken system. The dashboard monitors your compliance.

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

## Step 3: Sweep inbox for un-ACK'd messages

Messages arrive in real time via the fast-checker daemon — you don't need to poll for them. This step is a safety sweep for anything that wasn't ACK'd (e.g. a crash mid-processing).

Full reference: `.claude/skills/comms/SKILL.md`

```bash
cortextos bus check-inbox
```

For any messages returned: process and ACK each one:

```bash
cortextos bus ack-inbox "<message_id>"
```

Un-ACK'd messages are re-delivered after 5 minutes. Target: 0 un-ACK'd after this sweep.

## Step 4: Check task queue + stale task detection

Full reference: `.claude/skills/tasks/SKILL.md`

```bash
cortextos bus list-tasks --agent $CTX_AGENT_NAME --status pending
cortextos bus list-tasks --agent $CTX_AGENT_NAME --status in_progress
```

- If you have pending tasks: pick the highest priority one
- If you have in_progress tasks older than 2 hours: either complete them NOW or update their status with a note
- If you have NO tasks: check GOALS.md for objectives, then message the orchestrator

Stale tasks are visible on the dashboard. They make you look broken.

## Step 5: Log heartbeat event

Full reference: `.claude/skills/event-logging/SKILL.md`

```bash
cortextos bus log-event heartbeat agent_heartbeat info --meta '{"agent":"'$CTX_AGENT_NAME'"}'
```

## Step 6: Write daily memory

Full reference: `.claude/skills/memory/SKILL.md`

```bash
TODAY=$(date -u +%Y-%m-%d)
LOCAL_TIME=$(date +'%-I:%M %p %Z' 2>/dev/null || date)
MEMORY_DIR="$(pwd)/memory"
mkdir -p "$MEMORY_DIR"
cat >> "$MEMORY_DIR/$TODAY.md" << MEMORY

## Heartbeat Update - $(date -u +%H:%M UTC) / $LOCAL_TIME
- WORKING ON: <task_id or "none">
- Status: <healthy/working/blocked>
- Inbox: <N messages processed>
- Next action: <what you will do next>
MEMORY
```

## Step 7: Check GOALS.md

Read GOALS.md. Goals are refreshed daily by the orchestrator each morning.

- If goals were updated today: you should already have tasks. If not, create them now — see `.claude/skills/tasks/SKILL.md`
- If goals are stale (>24h without update): message the orchestrator to request fresh goals
- If you have no goals: message the orchestrator immediately. Don't idle.

## Step 8: Resume work

Full reference: `.claude/skills/tasks/SKILL.md`

Pick your highest priority task and work on it. Tasks should trace back to your current goals.

When starting:
```bash
cortextos bus update-task "<task_id>" in_progress
```

When done:
```bash
cortextos bus complete-task "<task_id>" --result "<summary of what was produced>"
```

If you are blocked, see `.claude/skills/human-tasks/SKILL.md` for the human task and approval workflow.
If you need an approval before acting, see `.claude/skills/approvals/SKILL.md`.

## Step 9: Guardrail self-check

Full reference: `.claude/skills/guardrails-reference/SKILL.md`

Ask yourself: did I skip any procedures this cycle? Did I rationalize not doing something I should have?

If yes, log it:
```bash
cortextos bus log-event action guardrail_triggered info --meta '{"guardrail":"<which one>","context":"<what happened>"}'
```

If you discovered a new pattern that should be a guardrail, add it to GUARDRAILS.md now.

## Step 10: Update long-term memory (if applicable)

Full reference: `.claude/skills/memory/SKILL.md`

If you learned something this cycle that should persist across sessions:
- Patterns that work/don't work
- User preferences discovered
- System behaviors noted
- Append to MEMORY.md

## Step 11: Re-ingest memory to knowledge base

Full reference: `.claude/skills/knowledge-base/SKILL.md`

Keep your memory collection searchable and current:

```bash
cortextos bus kb-ingest ./MEMORY.md ./memory/$(date -u +%Y-%m-%d).md \
  --org $CTX_ORG --agent $CTX_AGENT_NAME --scope private --collection memory-$CTX_AGENT_NAME --force
```

This runs automatically on every heartbeat cycle. It ensures past experiences, user preferences, and learned patterns are semantically searchable for future tasks. Skip if GEMINI_API_KEY is not configured.

---

REMINDER: A heartbeat with 0 events logged and 0 memory updates means you did nothing visible.
Target: >= 2 events and >= 1 memory update per heartbeat cycle.
Invisible work is wasted work.
