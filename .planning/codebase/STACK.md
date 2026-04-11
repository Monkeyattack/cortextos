# Technology Stack

**Analysis Date:** 2026-04-11

## Languages

**Primary:**
- TypeScript 6.x - All source code in `src/` and `dashboard/src/`

**Secondary:**
- Bash - Legacy shell wrappers in `bus/` that delegate to `dist/cli.js bus`
- Python - Optional knowledge-base subsystem (`knowledge-base/venv/` with `mmrag.py`)

## Runtime

**Environment:**
- Node.js >=20.0.0 (required; uses native `fetch`, `FormData`, `Blob`)

**Package Manager:**
- npm
- Lockfile: `package-lock.json` present (root and dashboard)

## Frameworks

**Core (daemon/CLI):**
- None — pure Node.js with zero runtime framework dependencies
- commander 14.x - CLI argument parsing (`src/cli/index.ts`)
- node-pty 1.x - PTY management for spawning Claude Code processes (`src/pty/agent-pty.ts`)

**Dashboard:**
- Next.js 16.2 (App Router) - Web dashboard (`dashboard/`)
- React 19.2 - UI layer
- Tailwind CSS 4.x - Styling
- shadcn/ui - Component library built on Base UI and Radix primitives

**Testing:**
- Vitest 4.x - Unit and integration test runner (root and dashboard)
- Playwright 1.58 - E2E tests (`tests/e2e/`, `tests/playwright/`)

**Build/Dev:**
- tsup 8.x - Bundles `src/` to `dist/` (root)
- tsc - Type checking (both root and dashboard)
- Next.js built-in compiler - Dashboard bundling

## Key Dependencies

**Critical (daemon/CLI):**
- `node-pty` ^1.1.0 - Native addon; spawns Claude Code in PTY. Required for agent lifecycle
- `chokidar` ^5.0.0 - File watching; used in dashboard watcher for SSE events
- `commander` ^14.0.3 - CLI argument parsing
- `@inquirer/prompts` ^8.3.2 - Interactive CLI setup prompts
- `chalk` ^5.6.2 - Terminal output coloring
- `ora` ^9.3.0 - Spinner output
- `strip-ansi` ^7.2.0 - Strips ANSI from PTY output

**Critical (dashboard):**
- `better-sqlite3` ^12.8.0 - Embedded SQLite; the dashboard's read cache
- `next-auth` ^5.0.0-beta.30 - Authentication (JWT sessions, credentials provider)
- `bcryptjs` ^3.0.3 - Password hashing for dashboard users
- `jose` ^6.2.2 - JWT verification in Edge Runtime middleware
- `recharts` ^3.8.0 - Analytics charts
- `@dnd-kit/core` + `@dnd-kit/sortable` - Drag-and-drop in workflow views
- `date-fns` ^4.1.0 - Date utilities

## Configuration

**Environment (daemon):**
- `CTX_INSTANCE_ID` - Instance namespace (default: `default`)
- `CTX_ROOT` - State directory (`~/.cortextos/{instanceId}`)
- `CTX_FRAMEWORK_ROOT` - Path to cortextos repo root
- `CTX_ORG` - Active organization name
- Agent-level secrets in `orgs/{org}/agents/{name}/.env` (BOT_TOKEN, CHAT_ID, ALLOWED_USER)
- Org-level secrets in `orgs/{org}/secrets.env` (OPENAI_KEY, APIFY_TOKEN, etc.)

**Environment (dashboard):**
- `AUTH_SECRET` - NextAuth JWT secret (required)
- `ADMIN_USERNAME` / `ADMIN_PASSWORD` - Seeded on first login
- `CTX_ROOT` / `CTX_FRAMEWORK_ROOT` - Mirrors daemon paths
- `NEXTAUTH_URL` - Public URL for auth redirects
- `MOBILE_APP_ORIGIN` - CORS origin for mobile app
- See `dashboard/.env.example` for complete reference

**Build:**
- `tsconfig.json` - Root TypeScript config (ES2022 target, bundler module resolution, strict mode)
- `dashboard/tsconfig.json` - Dashboard TypeScript config
- `tsup` config implied in `package.json` scripts (no explicit config file)
- `dashboard/postcss.config.mjs` - PostCSS for Tailwind v4

## Platform Requirements

**Development:**
- Node.js >=20.0.0
- `claude` CLI available in PATH (the Claude Code binary that agents run)
- PM2 (optional) for process management: `ecosystem.config.js`
- `cloudflared` (optional) for `cortextos tunnel` command (macOS-only)

**Production:**
- PM2 for daemon management (`ecosystem.config.js` or `dashboard-ecosystem.config.js`)
- Dashboard runs on port 3000 by default
- Daemon communicates via Unix socket at `~/.cortextos/{instanceId}/daemon.sock`

---

*Stack analysis: 2026-04-11*
