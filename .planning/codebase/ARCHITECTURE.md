# Architecture

**Analysis Date:** 2026-04-11

## Pattern Overview

**Overall:** Single-daemon process manager with file-based message bus, IPC socket control plane, and optional web dashboard

**Key Characteristics:**
- One daemon process (`dist/daemon.js`) manages all agents via `AgentManager`
- Agents ARE Claude Code processes — each agent is a `claude` CLI process spawned in a PTY
- File system is the source of truth for all agent state (JSON/JSONL files)
- CLI communicates with the running daemon via Unix socket IPC (not HTTP)
- Dashboard is a separate Next.js process that reads from the filesystem and a SQLite cache
- Multi-organization: agents are namespaced under `orgs/{org}/agents/{name}/`

## Layers

**Daemon Layer:**
- Purpose: Spawns and supervises all agent processes; handles crashes, session timers, restarts
- Location: `src/daemon/`
- Contains: `AgentManager`, `AgentProcess`, `IPCServer`, `FastChecker`, `WorkerProcess`
- Depends on: PTY layer, Bus layer, Telegram layer, Utils
- Used by: CLI (via IPC socket), nothing else

**PTY Layer:**
- Purpose: Wraps `node-pty` to spawn and manage Claude Code terminal sessions
- Location: `src/pty/`
- Contains: `AgentPTY` (spawns `claude` CLI), `OutputBuffer` (captures stdout), `inject.ts` (writes to PTY stdin)
- Depends on: `node-pty` native addon, `src/types/`
- Used by: `AgentProcess`, `WorkerProcess`

**Bus Layer:**
- Purpose: Agent-to-agent messaging, task management, events, heartbeats, approvals, experiments
- Location: `src/bus/`
- Contains: `message.ts`, `task.ts`, `event.ts`, `heartbeat.ts`, `approval.ts`, `system.ts`, `experiment.ts`, `catalog.ts`, `metrics.ts`, `reminders.ts`, `knowledge-base.ts`, `oauth.ts`
- Depends on: `src/utils/`, `src/types/`
- Used by: CLI (`cortextos bus` subcommands), daemon (via hooks), agents at runtime

**CLI Layer:**
- Purpose: User-facing command interface; delegates to daemon via IPC or operates directly on files
- Location: `src/cli/`
- Contains: One file per command (init, add-agent, start, stop, status, bus, enable-agent, etc.)
- Depends on: Bus layer, daemon IPC client, Telegram layer
- Used by: End users; also invoked by agents running `cortextos bus` commands inside their PTY

**Hooks Layer:**
- Purpose: Claude Code hook scripts triggered by agent lifecycle events (SessionEnd, PermissionRequest, PreToolUse)
- Location: `src/hooks/`
- Contains: `hook-crash-alert.ts`, `hook-ask-telegram.ts`, `hook-permission-telegram.ts`, `hook-planmode-telegram.ts`, `hook-compact-telegram.ts`, `hook-idle-flag.ts`, `hook-extract-facts.ts`
- Depends on: Telegram API (direct HTTP fetch), filesystem
- Used by: Claude Code agent processes (configured in `templates/{type}/.claude/settings.json`)

**Telegram Layer:**
- Purpose: Telegram Bot API integration for human-agent communication
- Location: `src/telegram/`
- Contains: `TelegramAPI` (HTTP client), `TelegramPoller` (long-polling), `logging.ts`, `media.ts`
- Depends on: Node.js native `fetch`
- Used by: `AgentManager` (polling), `FastChecker` (message injection), hooks

**Dashboard Layer:**
- Purpose: Next.js web UI for monitoring and controlling agents
- Location: `dashboard/`
- Contains: App Router pages, API routes, SQLite sync engine, SSE event stream
- Depends on: Reads from `CTX_ROOT` filesystem; communicates with daemon via IPC socket (same Unix socket as CLI)
- Used by: End users via browser; optionally mobile app via Bearer JWT

**Utils Layer:**
- Purpose: Shared primitives used throughout
- Location: `src/utils/`
- Contains: `atomic.ts` (atomic file writes via rename), `lock.ts` (file-based locking), `paths.ts` (canonical path resolution), `env.ts` (env var resolution), `validate.ts` (input sanitization), `random.ts`

## Data Flow

**Agent Message Flow:**

1. Sending agent calls `cortextos bus send-message <to> <priority> <text>` inside its PTY
2. `src/bus/message.ts:sendMessage()` creates a priority-prefixed JSON file in `inbox/{to}/`
3. `FastChecker` polling loop (1s interval) detects the new file via `checkInbox()`
4. If target agent is bootstrapped, `FastChecker` injects the formatted message into the agent's PTY stdin
5. Message moved to `inflight/{to}/` while being processed; moved to `processed/{to}/` on ack

**Telegram → Agent Flow:**

1. `TelegramPoller` calls `getUpdates` every ~1s (long polling)
2. Message arrives, `AgentManager` validates `ALLOWED_USER` gate
3. Media or text message is processed and formatted
4. `FastChecker.queueTelegramMessage()` enqueues the formatted message
5. `FastChecker` polling loop injects it into agent's PTY stdin when agent is bootstrapped

**Agent Lifecycle:**

1. Daemon starts → `AgentManager.discoverAndStart()` scans `{frameworkRoot}/orgs/*/agents/`
2. Each agent: `AgentProcess.start()` → `AgentPTY.spawn('fresh' | 'continue', prompt)` → `node-pty` spawns `claude`
3. Startup prompt tells agent to read AGENTS.md, restore crons, send Telegram online notification
4. Agent exits → `handleExit()` → if not intentional: exponential backoff restart; if crash limit exceeded: `halted`
5. Session timer fires (default 255600s / ~71h) → `sessionRefresh()` → stop + restart with `--continue`

**IPC Control Flow:**

1. CLI command runs (e.g. `cortextos restart boss`)
2. `IPCClient.send({ type: 'restart-agent', agent: 'boss' })` connects to `~/.cortextos/{instanceId}/daemon.sock`
3. `IPCServer.handleRequest()` routes to `agentManager.restartAgent('boss')`
4. Response sent back; CLI disconnects

**Dashboard Data Flow:**

1. Chokidar watcher (`dashboard/src/lib/watcher.ts`) monitors `CTX_ROOT` glob patterns
2. On file change: `syncFile()` upserts changed file into SQLite cache
3. SSE emitter broadcasts event type to all connected browser clients via `/api/events/stream`
4. Browser client receives event, refetches affected data from API routes
5. API routes read from SQLite cache (fast) or directly from filesystem (heartbeats)

**State Management:**
- Daemon state: in-memory `Map<string, AgentEntry>` in `AgentManager`
- Bus state: JSON files on disk under `CTX_ROOT`
- Dashboard state: SQLite cache + React component state
- Agent conversation history: managed by Claude Code in `~/.claude/projects/`

## Key Abstractions

**AgentProcess:**
- Purpose: Lifecycle manager for one agent (start/stop/restart/crash recovery)
- Examples: `src/daemon/agent-process.ts`
- Pattern: Owns an `AgentPTY`; handles exponential backoff, session timers, stop-marker coordination

**FastChecker:**
- Purpose: Per-agent message pump — polls inbox and Telegram queue, injects into PTY
- Examples: `src/daemon/fast-checker.ts`
- Pattern: 1-second polling loop with SIGUSR1/IPC wake support; persistent dedup via SHA-256 hash set

**BusPaths:**
- Purpose: Canonical directory structure for a given agent instance
- Examples: `src/utils/paths.ts`
- Pattern: All bus operations take a `BusPaths` struct rather than building paths ad-hoc

**WorkerProcess:**
- Purpose: Ephemeral Claude Code session for one-shot parallelized tasks (no crash recovery, no Telegram)
- Examples: `src/daemon/worker-process.ts`
- Pattern: Spawned via IPC `spawn-worker` command; auto-removes after 30s post-exit

**AgentConfig:**
- Purpose: Per-agent configuration read from `{agentDir}/config.json`
- Examples: `src/types/index.ts`
- Fields: `startup_delay`, `max_session_seconds`, `max_crashes_per_day`, `model`, `working_directory`, `crons`, `timezone`, `enabled`

## Entry Points

**Daemon:**
- Location: `src/daemon/index.ts` → compiled to `dist/daemon.js`
- Triggers: `pm2 start ecosystem.config.js` or `node dist/daemon.js`
- Responsibilities: Reads `CTX_FRAMEWORK_ROOT`, creates `AgentManager`, starts `IPCServer`, discovers and starts agents

**CLI:**
- Location: `src/cli/index.ts` → compiled to `dist/cli.js`
- Triggers: `cortextos <command>` (installed via `npm install -g cortextos`)
- Responsibilities: Routes commands; lifecycle commands go via IPC to daemon; bus commands operate on files directly

**Dashboard:**
- Location: `dashboard/src/app/(dashboard)/page.tsx`
- Triggers: Next.js dev server or `next start`
- Responsibilities: Serves web UI; API routes read from filesystem/SQLite; SSE stream pushes real-time updates

**Hooks (SessionEnd):**
- Location: `src/hooks/hook-crash-alert.ts` → compiled to `dist/hooks/hook-crash-alert.js`
- Triggers: Claude Code calls `cortextos crash-alert` on session end (configured in `.claude/settings.json`)
- Responsibilities: Categorizes exit type (crash/stop/refresh), sends Telegram alert

## Error Handling

**Strategy:** Fail-safe — prefer silent recovery over crash propagation; PTY errors are isolated per-agent

**Patterns:**
- Agent crashes trigger exponential backoff restart (not daemon restart)
- IPC errors return `{ success: false, error: string }` — never throw across socket boundary
- File operations wrapped in try/catch with silent fallback (bus operations continue if one message is corrupt)
- Stale inflight messages auto-recovered after 5 minutes
- Daemon writes `.daemon-stop` marker before stopping agents to prevent false crash alerts

## Cross-Cutting Concerns

**Logging:** `console.log/error` with `[component-name]` prefix; PM2 captures all stdout/stderr
**Validation:** Agent names, org names, priorities, instance IDs validated in `src/utils/validate.ts` before filesystem access
**Authentication:** Dashboard uses NextAuth JWT sessions + bcrypt passwords; bus messages optionally HMAC-signed; Telegram enforces numeric `ALLOWED_USER` gate
**File atomicity:** All writes use `atomicWriteSync()` (write to `.tmp.{random}` then `rename`) ensuring no corrupt partial reads
**File permissions:** Daemon sets `umask(0o077)`; sensitive files written with mode `0o600`

---

*Architecture analysis: 2026-04-11*
