# External Integrations

**Analysis Date:** 2026-04-11

## APIs & External Services

**Telegram Bot API:**
- Used for bidirectional agent communication — agents receive user messages and send notifications
- SDK/Client: Custom `TelegramAPI` class in `src/telegram/api.ts` (uses Node.js 20 native `fetch`, no external HTTP library)
- Auth: `BOT_TOKEN` in `orgs/{org}/agents/{name}/.env`
- Polling: `TelegramPoller` in `src/telegram/poller.ts` uses long-polling (`getUpdates`)
- Security gate: `ALLOWED_USER` numeric Telegram user ID required; daemon refuses to start Telegram without it
- Features: text messages, photos, documents, voice, audio, video, callback queries, typing indicators, slash command registration
- Rate limit: 1 message/second/chat enforced in `TelegramAPI.rateLimit()`

**Anthropic Claude Code CLI:**
- The core agent runtime — each agent IS a Claude Code process spawned in a PTY
- Invoked as: `claude [--continue] --dangerously-skip-permissions [--model <model>] <prompt>`
- Integration: `node-pty` spawns `claude` directly (no shell wrapper) via `AgentPTY.spawn()` in `src/pty/agent-pty.ts`
- Auth: `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` passed in PTY environment
- OAuth rotation: `src/bus/oauth.ts` manages multi-account token rotation with `accounts.json` at `state/oauth/accounts.json`

**Cloudflare Tunnel (`cloudflared`):**
- Optional — exposes the local dashboard to the internet
- CLI command: `cortextos tunnel` in `src/cli/tunnel.ts`
- macOS-only feature (checks platform before running)
- Manages LaunchAgent plist at `~/Library/LaunchAgents/com.cortextos.tunnel.plist`
- Config stored at `~/.cortextos/{instanceId}/tunnel.json`

## Data Storage

**Databases:**
- SQLite via `better-sqlite3` — dashboard read cache only
  - Location: `{CTX_ROOT}/dashboard/cortextos-{instanceId}.db` (or `.data/cortextos-{instanceId}.db` fallback)
  - Initialized in `dashboard/src/lib/db.ts`
  - WAL mode, `busy_timeout=10000`, `synchronous=NORMAL`
  - Tables: `tasks`, `approvals`, `events`, `heartbeats`, `cost_entries`, `users`, `messages`, `sync_meta`, `rate_limits`
  - The database is a cache — source of truth is JSON/JSONL files on disk

**File Storage (primary data store):**
- All agent state stored as JSON/JSONL files under `~/.cortextos/{instanceId}/`
- Agent inbox: `inbox/{agentName}/*.json` (priority-prefixed filenames)
- Task storage: `orgs/{org}/tasks/*.json`
- Approval storage: `orgs/{org}/approvals/*.json`
- Event logs: `orgs/{org}/analytics/events/{agent}/*.jsonl`
- Heartbeats: `state/{agent}/heartbeat.json`
- Conversation history: `~/.claude/projects/{agentDir-as-path}/*.jsonl` (managed by Claude Code)

**Knowledge Base:**
- Optional Python-based semantic search using `mmrag.py`
- Requires Python venv at `knowledge-base/venv/`
- Called via `src/bus/knowledge-base.ts` using `execFileSync`

## Authentication & Identity

**Dashboard Auth:**
- NextAuth v5 (credentials provider) in `dashboard/src/lib/auth.ts`
- Users stored in SQLite `users` table, passwords bcrypt-hashed (cost 12)
- JWT sessions (not database sessions)
- Cookie names: `authjs.session-token`, `authjs.csrf-token`
- Brute-force protection: rate limiting per IP in `dashboard/src/lib/rate-limit.ts`, persisted in SQLite `rate_limits` table
- Mobile app: Bearer JWT tokens verified with `jose` in Edge Runtime middleware (`dashboard/src/middleware.ts`)

**Message Bus Auth:**
- Optional HMAC-SHA256 message signing in `src/bus/message.ts`
- Signing key at `{CTX_ROOT}/config/bus-signing-key`
- Unsigned messages from legacy clients accepted with warning; new installations sign all messages

## Monitoring & Observability

**Error/Crash Tracking:**
- Internal — crash events written to `logs/{agent}/crashes.log`
- Telegram alerts on crash/halt/recovery via `src/hooks/hook-crash-alert.ts` (Claude Code SessionEnd hook)
- Crash count persisted in `logs/{agent}/.crash_count_today`
- Exponential backoff: `5s * 2^crashCount`, capped at 300s (5 minutes)

**Usage Monitoring:**
- `src/bus/metrics.ts` collects Claude token usage from agent output logs
- Cost entries synced to dashboard SQLite `cost_entries` table
- OAuth utilization tracked in `state/oauth/accounts.json` (5h and 7d rolling windows)

**Logs:**
- PTY stdout captured to `{CTX_ROOT}/logs/{agent}/stdout.log` via `OutputBuffer` in `src/pty/output-buffer.ts`
- Daemon process logs via `console.log` (managed by PM2)
- Telegram conversation logs: `{CTX_ROOT}/logs/{agent}/telegram-inbound.jsonl` and `telegram-outbound.jsonl`

## CI/CD & Deployment

**Hosting:**
- Self-hosted — daemon runs under PM2 on user's machine
- Dashboard: Next.js served by PM2 (dev) or `next start` (production)
- No cloud hosting built-in

**CI Pipeline:**
- GitHub Actions: `.github/workflows/ci.yml`
- Jobs: Build + Type Check, Unit Tests, Dashboard Build
- Runs on: ubuntu-latest, Node.js 20
- Secrets used: `CI_AUTH_SECRET`, `CI_ADMIN_PASSWORD`

## Webhooks & Callbacks

**Incoming:**
- Telegram Bot API long-polling (not webhooks) — `TelegramPoller` polls `getUpdates` continuously
- Telegram callback queries (inline keyboard button presses) — handled by `FastChecker.handleCallback()`

**Outgoing:**
- Telegram Bot API calls for: `sendMessage`, `sendPhoto`, `sendDocument`, `sendChatAction`, `editMessageText`, `setMyCommands`, `answerCallbackQuery`

## Environment Configuration

**Required daemon env vars:**
- `CTX_FRAMEWORK_ROOT` - Daemon exits with error if unset
- `CTX_INSTANCE_ID` - Instance namespace (defaults to `default`)
- `CTX_ORG` - Organization name for fallback resolution

**Required dashboard env vars:**
- `AUTH_SECRET` - Refuses to start without this
- `ADMIN_PASSWORD` - Required on first boot to seed admin user
- `CTX_ROOT` and `CTX_FRAMEWORK_ROOT` - For reading agent/org data

**Secrets location:**
- Agent-level: `orgs/{org}/agents/{name}/.env` (BOT_TOKEN, CHAT_ID, ALLOWED_USER, CLAUDE_CODE_OAUTH_TOKEN)
- Org-level: `orgs/{org}/secrets.env` (shared secrets across all agents in org)
- Dashboard: `dashboard/.env.local` (gitignored)
- Bus signing key: `{CTX_ROOT}/config/bus-signing-key`
- OAuth accounts: `{CTX_ROOT}/state/oauth/accounts.json` (access + refresh tokens)

---

*Integration audit: 2026-04-11*
