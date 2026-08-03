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

## Step 2: Sweep inbox for un-ACK'd messages

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

## Step 3: Pull your PM work queue

**PM is the work queue. The local bus task store is operational only.**

These are two different systems that share an ID format — filing SOW work in the bus store
makes it invisible to the SOW. Deliverable work goes in PM; ephemeral operational notes
(cron ran, sweep clean) stay in the bus store.

```bash
PM_API_KEY=$(grep PM_API_KEY /home/claude-dev/repos/pm-system/.env | cut -d= -f2 | tr -d '"')
curl -s "https://pm.profithits.app/api/tasks?assignee=$CTX_AGENT_NAME" \
  -H "x-api-key: $PM_API_KEY" | python3 -c "
import json,sys
ts=[t for t in json.load(sys.stdin) if t.get('status') in ('pending','in_progress')]
ts.sort(key=lambda t:(t.get('due_date') or '9999', t.get('created_at') or ''))
for t in ts: print(t['status'], t.get('due_date','no-due'), t['id'], t['title'][:70])"
```

- **Overdue or due today** outranks everything else. Work it or flag it — never let it pass silently.
- **in_progress older than 2 hours** with no commit or artifact behind it: close it or say why it stalled.
- **No PM tasks at all**: check GOALS.md, then message the orchestrator. Do not invent work.

Stale tasks are visible on the dashboard. They make you look broken.

### Fan-out plan (required before you start)

Before working the queue, decide what gets delegated. **Independent tasks run in parallel or you
are wasting the fleet.**

For each task, ask: does it depend on the output of another task in this queue? If no, it is
independent and eligible for a worker.

```bash
cortextos spawn-worker <name> --runtime codex --task "<focused task + acceptance criteria>"
```

- **`--runtime codex` is the default** for pure-code work. Use `claude` only for architecture
  review, cortextOS PRs, or content judgment.
- Give the worker a **slim bootstrap**: the one task, its acceptance criteria, and the paths it
  needs. Do not hand it your whole context.
- **Every spawn gets a PM task recorded immediately** — worker name, what it is doing, expected
  completion. That is the crash-recovery record.
- Your own context is for coordination, gates, and comms. Not for work a worker can do.

**Serial-work detector — if all of the following are true, you are doing it wrong:**
you hold 2+ independent PM tasks, you have spawned no workers, and your last worker spawn was
over 24 hours ago. Stop and fan out before continuing.

## Step 4: Log heartbeat event

Full reference: `.claude/skills/event-logging/SKILL.md`

```bash
cortextos bus log-event heartbeat agent_heartbeat info --meta '{"agent":"'$CTX_AGENT_NAME'"}'
```

## Step 5: Write daily memory

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

## Step 6: Check GOALS.md

Read GOALS.md. Goals are refreshed daily by the orchestrator each morning.

- If goals were updated today: you should already have tasks. If not, create them now — see `.claude/skills/tasks/SKILL.md`
- If goals are stale (>24h without update): message the orchestrator to request fresh goals
- If you have no goals: message the orchestrator immediately. Don't idle.

## Step 7: Work the queue, close with evidence

Full reference: `.claude/skills/tasks/SKILL.md`

Work the PM queue from Step 3 in the order you sorted it, with the delegated tasks already
running in workers. Every task traces back to a SOW milestone — if one does not, it does not
belong in PM.

When starting:
```bash
curl -s -X PATCH "https://pm.profithits.app/api/tasks/<task_id>" \
  -H "x-api-key: $PM_API_KEY" -H "Content-Type: application/json" \
  -d '{"status":"in_progress"}'
```

When done — **a close needs a real artifact, not a claim**:
```bash
curl -s -X PATCH "https://pm.profithits.app/api/tasks/<task_id>" \
  -H "x-api-key: $PM_API_KEY" -H "Content-Type: application/json" \
  -d '{"status":"completed","description":"<prior description>\n\nDONE <UTC>: <what changed> | EVIDENCE: <commit SHA / URL / file path / verbatim command + output>"}'
```

Valid evidence is a commit SHA, a URL that returns 200, a file path that exists, or a command
with its output. Spec text, a restatement of the plan, or "PROOF: X" as a placeholder are not
evidence and get reverted in sweeps.

**Report SOW progress, not activity.** At the end of the cycle, state which milestone moved and
by how much — "M3 3/7, parallel-dispatch closed" beats "worked on tasks."

If you are blocked, see `.claude/skills/human-tasks/SKILL.md` for the human task and approval workflow.
If you need an approval before acting, see `.claude/skills/approvals/SKILL.md`.

## Step 8: Guardrail self-check

Full reference: `.claude/skills/guardrails-reference/SKILL.md`

Ask yourself: did I skip any procedures this cycle? Did I rationalize not doing something I should have?

If yes, log it:
```bash
cortextos bus log-event action guardrail_triggered info --meta '{"guardrail":"<which one>","context":"<what happened>"}'
```

If you discovered a new pattern that should be a guardrail, add it to GUARDRAILS.md now.

## Step 9: Update long-term memory (if applicable)

Full reference: `.claude/skills/memory/SKILL.md`

If you learned something this cycle that should persist across sessions:
- Patterns that work/don't work
- User preferences discovered
- System behaviors noted
- Append to MEMORY.md

## Step 10: Re-ingest memory to knowledge base

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
