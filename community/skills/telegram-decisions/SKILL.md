---
name: telegram-decisions
description: Send tappable inline keyboard decision buttons to Chris via Telegram. Use whenever you need Chris to choose between options — replaces text walls and reply-based approvals. Also handles crash-recovery resend of stale decisions.
triggers:
  - decision
  - send-decision
  - inline keyboard
  - button
  - yes no
  - choose
  - pick one
  - approve or reject
  - options
  - resend decisions
  - pending decisions
---

# Telegram Inline Keyboard Decisions

## When to use
Use `send-decision` any time you need Chris to pick between discrete options:
- YES/NO approvals
- Pick-one-of-N choices (strategy A vs B vs C, etc.)
- HOLD/DEFER options on decisions queue items
- Any case where you'd otherwise ask a question and wait for a typed reply

**Do not send a text question and wait for a text reply when you could use a button.**

## Commands

### Send a decision
```bash
cortextos bus send-decision "$CTX_TELEGRAM_CHAT_ID" \
  "Short title (one line)" \
  "Context and details — what this is about, what each option means" \
  --options "YES,NO,HOLD" \
  --agent "$CTX_AGENT_NAME"
```

- `--options` defaults to `YES,NO,HOLD` if omitted
- Custom options: `--options "Path A,Path B,Defer"` (comma-separated, no spaces around commas)
- Returns `id=<uuid> message_id=<telegram_msg_id>` on success
- Buttons appear inline under your message in Telegram — Chris taps, it registers

### Check decision status
```bash
# All pending
cortextos bus list-decisions --status pending

# All resolved (see what Chris picked)
cortextos bus list-decisions --status resolved

# All (default limit 20)
cortextos bus list-decisions
```

Output columns: `ID  AGE  STATUS  CHOSEN  TITLE`

## Patterns

### Binary approval
```bash
cortextos bus send-decision "$CTX_TELEGRAM_CHAT_ID" \
  "Deploy config change to accounts" \
  "Updated Apex max-contracts from 6 to 8 per H27 approval. Ready to deploy." \
  --options "YES,NO"
```

### Multi-option pick
```bash
cortextos bus send-decision "$CTX_TELEGRAM_CHAT_ID" \
  "AMAZONIAN cover path" \
  "Three options: (A) Use existing square composited cover, (B) Regenerate with new aspect, (C) Hold for now" \
  --options "A - Use existing,B - Regenerate,C - Hold"
```

### Batch decisions
Send one `send-decision` call per item. Do NOT batch all choices into one message.
Each decision is a separate button — Chris taps each independently.

## Crash Recovery / Resend Pattern

**When a session crashes, restarts, or loses context — any decisions that were pending before the crash are lost to Chris's Telegram as un-tappable old messages.**

### Rule

After any session restart, immediately check for stale pending decisions and resend them all with fresh buttons.

```bash
# 1. Check what's pending
cortextos bus list-decisions --status pending

# 2. For each pending decision, resend with send-decision
cortextos bus send-decision "$CTX_TELEGRAM_CHAT_ID" \
  "[Original title]" \
  "↩️ Resent after session restart. [Original context]" \
  --options "ORIGINAL,OPTIONS,HERE" \
  --agent "$CTX_AGENT_NAME"
```

### Also send a summary message first

```bash
cortextos bus send-telegram "$CTX_TELEGRAM_CHAT_ID" \
  "Session restarted. Resending N pending decisions below — previous buttons no longer work."
```

### Why
- Tap callbacks on pre-crash messages are registered but may not reach the restarted session's fast-checker
- Chris cannot know which decisions survived the restart
- Never assume a pre-crash decision was captured — always resend

### Scope
**All agents** follow this pattern, not just chief. Any agent that uses `send-decision` must resend pending decisions after a crash or restart.

## Implementation notes
- State lives in `~/.cortextos/$CTX_INSTANCE_ID/state/pending-decisions.json` (atomic writes, survives restarts)
- Callbacks resolve via fast-checker (decision_<id>_<optionIndex> prefix)
- Resolved decisions stay in state with `chosen` field set
- Commit: 1fd4715 (cortextos src/bus/decision.ts + src/daemon/fast-checker.ts)
- GitHub: issue #312

## Do not use for
- Long-form feedback requests (use send-telegram for those)
- Tasks that require Chris to provide free-text input
- Decisions that auto-resolve by system logic (no user input needed)
