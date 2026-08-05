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

## Step 7: Check GOALS.md

Read GOALS.md for any new objectives. If goals changed, create tasks:
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
