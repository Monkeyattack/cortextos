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

## Step 2: Check inbox

```bash
cortextos bus check-inbox
```

Process ALL messages. ACK every single one:
```bash
cortextos bus ack-inbox "<message_id>"
```

Un-ACK'd messages are re-delivered in 5 minutes.
Target: 0 un-ACK'd messages after this step.

## Step 3: Pull your PM work queue

```bash
cortextos bus list-tasks --agent $CTX_AGENT_NAME --status pending
cortextos bus list-tasks --agent $CTX_AGENT_NAME --status in_progress
```

- **Pull your PM queue first** — PM is the work queue; the local bus task store is
  operational only. Deliverable work lives in PM:
  ```bash
  PM_API_KEY=$(grep PM_API_KEY /home/claude-dev/repos/pm-system/.env | cut -d= -f2 | tr -d '"')
  curl -s "https://pm.profithits.app/api/tasks?assignee=$CTX_AGENT_NAME" \
    -H "x-api-key: $PM_API_KEY" | python3 -c "
  import json,sys
  ts=[t for t in json.load(sys.stdin) if t.get('status') in ('pending','in_progress')]
  ts.sort(key=lambda t:(t.get('due_date') or '9999', t.get('created_at') or ''))
  for t in ts: print(t['status'], t.get('due_date','no-due'), t['id'], t['title'][:70])"
  ```
- **Overdue or due today outranks everything.** Work it or flag it — never let it pass silently.
- **Fan out before you start.** Any PM task that does not depend on another task's output goes
  to a worker: `cortextos spawn-worker <name> --runtime codex --task "<task + acceptance criteria>"`.
  Codex is the default for pure-code work; claude only for architecture review, cortextOS PRs, or
  content judgment. Give the worker a slim bootstrap — the task, its acceptance criteria, the paths
  it needs. Record every spawn as a PM task immediately; that is the crash-recovery record.
- **Serial-work detector:** 2+ independent PM tasks, no workers spawned, and 24h since your last
  spawn means you are doing it wrong. Stop and fan out.

## Step 4: Log heartbeat event

```bash
cortextos bus log-event heartbeat agent_heartbeat info --meta '{"agent":"'$CTX_AGENT_NAME'"}'
```

## Step 5: Write daily memory

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

## Step 6: Re-index memory to KB

```bash
cortextos bus kb-ingest ./MEMORY.md ./memory/$(date -u +%Y-%m-%d).md \
  --org $CTX_ORG --agent $CTX_AGENT_NAME --scope private --force
```

## Step 7: Check goals.json

Read `goals.json` for any new objectives (NOT GOALS.md — that is a rendered copy that can lag the source). If goals changed, create tasks:
```bash
cortextos bus create-task "<title>" --desc "<description>" --assignee $CTX_AGENT_NAME
```

## Step 8: Resume work

Work the PM queue in the order you sorted it, with delegated tasks already running in workers.
Every task traces back to a SOW milestone — if it does not, it does not belong in PM.

**A close needs a real artifact, not a claim.** Valid evidence is a commit SHA, a URL that
returns 200, a file path that exists, or a command with its output. Spec text and "PROOF: X"
placeholders are not evidence and get reverted in sweeps.

```bash
curl -s -X PATCH "https://pm.profithits.app/api/tasks/<task_id>" \
  -H "x-api-key: $PM_API_KEY" -H "Content-Type: application/json" \
  -d '{"status":"completed","description":"<prior>

DONE <UTC>: <what changed> | EVIDENCE: <SHA/URL/path/cmd+output>"}'
```

**Report SOW progress, not activity** — "M3 3/7, parallel-dispatch closed" beats "worked on tasks".

```bash
cortextos bus update-task "<task_id>" in_progress
# ... do the work ...
cortextos bus complete-task "<task_id>" "<summary of what was produced>"
```

---

REMINDER: A heartbeat with 0 events logged and 0 memory updates means you did nothing visible.
Target: >= 2 events and >= 1 memory update per heartbeat cycle.

## Context Discipline (fleet standard, 2026-08-03)

Your main session context is a scarce resource. Long sessions degrade you: deep-context
agents fail small tasks, hallucinate task completions, and lose track of guardrails.
Both fleet evidence-fabrication strikes happened deep in long sessions.

- **Delegate reads and research to in-session subagents (the Agent tool).** Reading files,
  sweeping logs, or exploring a codebase in your main context burns it permanently. A subagent
  reads everything and returns only the conclusion. If answering means reading more than ~2
  files, spawn a subagent for it.
- **Delegate builds to workers** (`cortextos spawn-worker`, codex default) — see the fan-out
  plan in Step 3. Main context is for coordination, gates, and comms only.
- **Daily fresh boot is scheduled** (daily-context-reset cron). Do not fight it — save
  in-flight state to memory when it fires and let the restart happen.
- **At ~60% context, write a session-parse to memory** (5 categories, fleet standard) without
  waiting for the reset.
- **If the session-size watchdog flags you** (chief relays a >25MB transcript alert), finish
  the current atomic step, save state, and run
  `cortextos bus hard-restart --reason context-hygiene` yourself.

## Telegram channel health probe — run every heartbeat cycle

Added 2026-08-12. The live agents already carry this check; the templates did not, so every
NEW agent was born unable to notice its own Telegram channel was dead. That is the exact
failure that motivated it: braindump's channel had a placeholder BOT_TOKEN and three full
heartbeat cycles passed with nobody detecting it, because there was no check to skip.

Run this every cycle. It is fail-quiet by design — a missing .env or a placeholder token
skips silently, so agents with no Telegram channel are not spammed. Only a real token that
fails to authenticate logs an error.

```bash
# Locate this agent's .env — skip silently if absent or placeholder token
AGENT_ENV=$(find /home/claude-dev/cortextos/orgs -name ".env" -path "*/${CTX_AGENT_NAME}/.env" 2>/dev/null | head -1)
if [[ -z "$AGENT_ENV" ]] || ! grep -q '^BOT_TOKEN=' "$AGENT_ENV" 2>/dev/null; then
  echo "[heartbeat] Telegram probe: no .env or BOT_TOKEN — skipping"
else
  # shellcheck source=/dev/null
  source "$AGENT_ENV"
  # POSITIVE gate: probe only what LOOKS like a real bot token (<digits>:<secret>).
  # This was a denylist (NEEDS_NEW|PLACEHOLDER|CHANGEME|{{) and it failed open on
  # every sentinel nobody had thought of. `bus-only` — the sentinel marking a
  # backend agent with no Telegram bot at all — is on no denylist, so it fell
  # through, got curl'd at getMe as a credential, and got md5'd by the collision
  # check below. Two bus-only agents then "collide" with perfect confidence,
  # because they DO share a string: the sentinel. md5("bus-only") = f651e7e6.
  # `none` (2 agents) failed the same way. A denylist can only exclude the fakes
  # someone already listed; a positive gate excludes every value that is not a
  # token, including the ones invented tomorrow.
  if ! printf '%s' "${BOT_TOKEN:-}" | grep -qE '^[0-9]{6,}:[A-Za-z0-9_-]{30,}$'; then
    echo "[heartbeat] Telegram probe: BOT_TOKEN is not a real bot token (sentinel/placeholder/empty) — skipping"
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
      # Same positive gate. Without it, every agent sharing a SENTINEL is
      # reported as sharing a CREDENTIAL — a false alarm that is confident,
      # reproducible and completely wrong about what it measured.
      printf '%s' "$other_token" | grep -qE '^[0-9]{6,}:[A-Za-z0-9_-]{30,}$' || continue
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
