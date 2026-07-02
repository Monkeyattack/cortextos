# Claude Remote Agent

Persistent 24/7 Claude Code agent controlled via Telegram. Runs via cortextos daemon with auto-restart and crash recovery.

## First Boot Check

**If the startup prompt contains "SESSION CONTINUATION"** — skip this check entirely. You are already onboarded. Proceed directly to AGENTS.md.

Otherwise, check if this agent has been onboarded:
```bash
# Primary: .onboarded marker. Fallback: heartbeat.json means the agent has run before.
[[ -f "${CTX_ROOT}/state/${CTX_AGENT_NAME}/.onboarded" ]] || \
  [[ -f "${CTX_ROOT}/state/${CTX_AGENT_NAME}/heartbeat.json" ]] \
  && echo "ONBOARDED" || echo "NEEDS_ONBOARDING"
```

If `NEEDS_ONBOARDING`: read `.claude/skills/onboarding/SKILL.md` and follow its instructions. Do NOT proceed with normal operations until onboarding is complete. The user can also trigger onboarding at any time by saying "run onboarding" or "/onboarding".

If `ONBOARDED`: continue with the session start protocol in **AGENTS.md** (canonical 14-step checklist, task workflow, memory protocol, event logging, telegram/agent message formats, crons, restart). This file is a reference card — AGENTS.md is authoritative.

---

## System Management

### Agent Lifecycle
| Action | Command |
|--------|---------|
| Add agent | `cortextos add-agent <name> --template <type>` |
| Start agent | `cortextos start <name>` |
| Stop agent | `cortextos stop <name>` |
| Check status | `cortextos status` |

### Communication
| Action | Command |
|--------|---------|
| Send Telegram | `cortextos bus send-telegram <chat_id> "<msg>"` |
| Send to agent | `cortextos bus send-message <agent> <priority> '<msg>' [reply_to]` |
| Check inbox | `cortextos bus check-inbox` |
| ACK message | `cortextos bus ack-inbox <msg_id>` |

### Logs
| Log | Path |
|-----|------|
| Activity | `~/.cortextos/$CTX_INSTANCE_ID/logs/$CTX_AGENT_NAME/activity.log` |
| Fast-checker | `~/.cortextos/$CTX_INSTANCE_ID/logs/$CTX_AGENT_NAME/fast-checker.log` |
| Stdout | `~/.cortextos/$CTX_INSTANCE_ID/logs/$CTX_AGENT_NAME/stdout.log` |
| Stderr | `~/.cortextos/$CTX_INSTANCE_ID/logs/$CTX_AGENT_NAME/stderr.log` |

### State
| File | Purpose |
|------|---------|
| `config.json` | Crons, max_session_seconds, agent config |
| `.env` | BOT_TOKEN, CHAT_ID, ALLOWED_USER |
