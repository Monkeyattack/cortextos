# Heartbeat Checklist - EXECUTE EVERY STEP. SKIP NOTHING.

This runs on your heartbeat cron (every 4 hours). Execute EVERY step in order.
Skipping steps = broken system. The dashboard monitors your compliance.

## Step 1: Update heartbeat (DO THIS FIRST)

```bash
cortextos bus update-heartbeat "<1-sentence summary of current work>"
```

If this fails, your agent shows as DEAD on the dashboard. Fix it before anything else.

**Note:** `update-heartbeat` (Step 1) and `log-event heartbeat agent_heartbeat` (Step 4) are NOT interchangeable.
- `update-heartbeat` refreshes the dashboard status-string field.
- `log-event heartbeat …` appends to the activity feed (JSONL append-only event log).

Both are required every cycle.

## Step 2: Sweep inbox for un-ACK'd messages

Messages arrive in real time via the fast-checker daemon. This step is a safety sweep for anything that wasn't ACK'd.

Full reference: `plugins/cortextos-agent-skills/skills/comms/SKILL.md`

```bash
cortextos bus check-inbox
```

For any messages returned: process and ACK each one:

```bash
cortextos bus ack-inbox "<message_id>"
```

Un-ACK'd messages are re-delivered after 5 minutes. Target: 0 un-ACK'd after this sweep.

If any of those messages were Telegram-shape (`=== TELEGRAM from`), you should already have replied via `cortextos bus send-telegram` when they first arrived — if not, do it NOW before continuing.

## Step 3: Pull your PM work queue

Full reference: `plugins/cortextos-agent-skills/skills/tasks/SKILL.md`

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

Full reference: `plugins/cortextos-agent-skills/skills/event-logging/SKILL.md`

```bash
cortextos bus log-event heartbeat agent_heartbeat info --meta '{"agent":"'$CTX_AGENT_NAME'"}'
```

## Step 5: Write daily memory

Full reference: `plugins/cortextos-agent-skills/skills/memory/SKILL.md`

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

## Step 6: Check GOALS.md

Read GOALS.md. Goals are refreshed daily by the orchestrator each morning.

- If goals were updated today: you should already have tasks. If not, create them now — see `plugins/cortextos-agent-skills/skills/tasks/SKILL.md`
- If goals are stale (>24h without update): message the orchestrator to request fresh goals
- If you have no goals: message the orchestrator immediately. Don't idle.

## Step 7: Resume work

Full reference: `plugins/cortextos-agent-skills/skills/tasks/SKILL.md`

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

When starting:
```bash
cortextos bus update-task "<task_id>" in_progress
```

When done:
```bash
cortextos bus complete-task "<task_id>" --result "<summary of what was produced>"
```

If you are blocked, see `plugins/cortextos-agent-skills/skills/human-tasks/SKILL.md` for the human task and approval workflow.
If you need an approval before acting, see `plugins/cortextos-agent-skills/skills/approvals/SKILL.md`.

## Step 8: Guardrail self-check

Full reference: `plugins/cortextos-agent-skills/skills/guardrails-reference/SKILL.md`

Ask yourself: did I skip any procedures this cycle? Did I rationalize not doing something I should have?

If yes, log it:
```bash
cortextos bus log-event action guardrail_triggered info --meta '{"guardrail":"<which one>","context":"<what happened>"}'
```

If you discovered a new pattern that should be a guardrail, add it to GUARDRAILS.md now.

## Step 9: Update long-term memory (if applicable)

Full reference: `plugins/cortextos-agent-skills/skills/memory/SKILL.md`

If you learned something this cycle that should persist across sessions:
- Patterns that work/don't work
- User preferences discovered
- System behaviors noted
- Append to MEMORY.md

## Step 10: Re-ingest memory to knowledge base

Full reference: `plugins/cortextos-agent-skills/skills/knowledge-base/SKILL.md`

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
