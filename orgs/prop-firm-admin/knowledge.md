# Organization Knowledge Base

Shared facts, context, and institutional knowledge for all agents in this org. Read on every session start. Update when you learn something that all agents should know.

## Business

Prop firm account management across futures and forex. Primary activities:
- Purchasing and managing evaluation accounts across multiple prop firms
- Tracking account lifecycle: eval → funded → active → failed/archived
- Copy trading across multiple platforms and accounts
- Profit tracking via custom dashboard

### Prop Firms - Futures
- **Apex Trader Funding** (primary) - 5 evals, 9 funded currently
  - **Apex 4.0 launched March 1, 2026** — major ruleset overhaul
  - **Account sizes (current):** $25K, $50K, $75K, $100K, $150K (max). **$250K and $300K tiers discontinued** in 4.0.
  - **Billing:** Monthly subscriptions replaced by **one-time payment** per account.
  - **Rules removed in 4.0:** MAE rule, 5:1 Risk-Reward rule, One Direction rule, 7-day min trading day, manual payout review, account resets.
  - **Drawdown options:** Intraday trailing OR End-of-Day (EOD) trailing — EOD is a real option for the first time.
  - **Payout lifecycle:** 6 payouts per PA, then PA is retired. Up to **20 active PAs** simultaneously across EOD/Intraday/Legacy.
  - **Eval pricing ($50K, with coupon):** Intraday trail = **$24.90** | EOD trail = **$34.90**. Use intraday trail for MOV — strategy exits same-session, so intraday unrealized peak exposure is minimal.
  - **$50K eval pass conditions:** $3,000 profit target, max $2,000 drawdown, no daily loss limit (intraday trail), 30 days, min 1 trading day.
  - **$50K PA payout conditions (4.0, confirmed from UI):** Balance ≥ $52,600 (safety net) | ≥ 8 trading days since last payout | ≥ 5 days with **$50+ profit** since last payout | No single day > 30% of cumulative profit (consistency rule).
  - **$50K PA drawdown:** $2,000 EOD trailing. Safety net = $52,600. Max contracts: 6 mini / 60 micro.
  - Open question: confirm whether our current funded accounts are Legacy or 4.0 — affects rotation strategy and lifecycle cap.
- **Lucid** — $25K–$150K. Tiers: LucidFlex (no daily loss), LucidPro (40% consistency), LucidDirect (20% consistency), LucidMaxx (invite-only). **HFT bots prohibited** (non-HFT automation OK). Must trade at least once every 20 days. Payouts process in ~15 minutes.
- **My Funded Futures (MFFU)** — rebuilt plan lineup July 2025. Plans: Core ($50K only, 40% consistency, $5K cycle cap), Rapid ($50K–$150K, 4% intraday trailing drawdown, no consistency), Pro ($50K–$150K, no consistency, no cycle cap). Account cap: 5 if only $25K/$50K; **3 if any $100K+**.
- **Tradeify** — $25K–$150K eval (funding up to $750K). Families: Growth (no consistency), Select (40% consistency, 1.5x multiplier, max $90K payout across 5 accounts), Lightning (instant funding). Max trailing drawdown across all families as of April 2026. Position limits scale with account size: 1 contract ($25K) → 15 contracts ($150K).

### Prop Firms - Forex
- **Upcomers** (upcomers.com) — up to $200K accounts, scaling to $2.5M. **EA/automation policy REVERSED May 2025: EAs now allowed on all 5 platforms** (previously banned; corrected 2026-07-14 via analyst FundedNext brief). Still banned: 3rd-party/cloud copy trading (permanent ban), intra-account hedging. Copy trading allowed between trader's own accounts. News trading allowed in challenge, NOT in funded phase.
- **FundedNext** (fundednext.com) — evaluated 2026-07-14 (analyst brief, artifact 561109a2): FUTURES = NO-BUY for flip (#7 of 7: Rapid Daily/Pro discontinued Jul-10-2026; Flex $1,500/5-day payout cap, 40% eval consistency, 80% split, 5-account max; NT8 via Tradovate only). CFD = CONDITIONAL: MT4/MT5 EAs allowed w/ PAID ADD-ON (banned on cTrader/Match-Trader); strategy-continuity rule eval->funded; MetaCopier legal ONLY own-Challenge-accounts local/VPS <$300K; **Duplikium EXPLICITLY NAMED & BANNED** (spelled 'Duplikum' in their docs) + grid trading = termination; signal services = permanent ban. Stellar 2-Step static drawdown = genuinely EA-friendly. MCP server (mcp.fundednext.com): first prop firm w/ agent-native API — 156 tools read-only incl. 10-tool market-data layer; 12 deprecated tools return 500; token customer-scoped, expiry undocumented (stress-test before 24/7 loops).
- **FundedHive** (fundedhive.com) — *NOTE: previously called "FundingHive" in this doc — actual firm name is FundedHive*. DIFC Dubai, launched 2025. Static drawdowns (5% daily, 10% max). **COPY TRADING PROHIBITED in all scenarios.** HFT, arbitrage, reverse trading also prohibited. News trading allowed.

### Compliance Risks (deferred per Chris 2026-04-12)
- **FundedHive copy ban** vs our MetaCopier/Duplikium copy-trading setup — potential violation if MT5 copy tools point at FundedHive accounts. **Deferred — Chris said EA and copy trade rules are being ignored for now.**
- **Upcomers automation ban** vs our MT5 EAs — potential violation if EAs are deployed to Upcomers. **Deferred, same reason.**

Source: `orgs/prop-firm-admin/agents/analyst/competitor-intel-2026-04.md` (2026-04-12).

### Trading Infrastructure
- **NinjaTrader** - 2 VPS instances uploading trade data to dashboard
- **MT5 EAs** - multiple expert advisors deployed
- **Copy Trading** - MetaCopier and Duplikium for MT5 copy trading
- **OrbFutures** - trading app, currently being deployed

## Team

- Owner/operator managing all accounts and infrastructure

## Technical

### Remote VPS
- SSH alias: `maprod`
- Projects directory: `~/repos/` on remote
- Hosts several apps including dashboard and trading tools
- Long-term plan: migrate all workloads to VPS to eliminate local power requirements and firewall holes

### Local Setup
- macOS workstation (current primary)
- cortextOS running locally for now

### Key Services
- NinjaTrader (2 VPS instances)
- MT5 with EAs
- MetaCopier (MT5 copy trading)
- Duplikium (MT5 copy trading)
- OrbFutures app (deploying)

### Strategy Status (current as of 2026-07-17 15:54 UTC)
| Strategy | Status | Accounts | Notes |
|---|---|---|---|
| H137_BilateralBreakout | ⚠️ MANUALLY REBUILT | PAAPEX4333770000017, TAKEPROFITPRO392542906 | **2026-07-17 12:36 CT CRITICAL: All strategies failed to restore @ 4:30 PM — custom assemblies missing/corrupted. Chris manually recreated all strategies (H137 included). Root cause: NT8 DLL failure. Escalated to devops for investigation + prevention.** |
| BrainExecutor | ACTIVE | MFFUEVFLX450774017, TAKEPROFITPRO392542906 | v1.2.0 current on HolyGrail NT8. Execution engine for H137 and other strategies. |
| MarketOpenVolatility (MOV) on MES | ACTIVE | PAAPEX4333770000017 | MES RTH volatility plays. Active and clean as of 2026-07-16. |
| MarketOpenVolatility (MOV) on MNQ | REVIEW | — | MNQ REVIEW chronic (WR 27.8%, -$1,212). Under review — may gate. |
| MCL (crude oil ORB strategy) | RETIRED 2026-07-12 | — | H152 ADX filter DISCARDED (only viable fix path failed). OVX 59.0 HARD-CAUTION, no near-term return to OVX<40 edge zone. Left portfolio with 0 commodity exposure — all remaining strategies are equity-index correlated. |
| MarketOpenFlip (FLIP) | ACTIVE | LTE05059758350006, MFFUEVFLX450774017 | Fires at 8:29-8:30 CT open. |
| FullPort Algo | ACTIVE | PPNTPPX50024895000001, Sim101 | |
| Excalibur | ACTIVE — WATCH | MFFUEVFLX450774017 | 7d -$3,052, all-time -$19,766. Chris directive: KEEP RUNNING (2026-06-04). |
| GapFill | ACTIVE | TDFYG50201122518 | |

### Cross-Org Projects Status

**Novelscribe Ph2 Blocker (2026-07-17):**
- Ph2 launch blocked on: HIGGSFIELD_API_KEY (task_1784157933698_qj3ptu — pending) + Chris approval
- Ph1 (billing infrastructure) complete, Ph1.1-1.6 (checkout/portal/webhook/entitlements/revisions/pricing/dashboard) in_progress
- First publish pending: HIGGSFIELD_API_KEY for brand video production
- **Action:** devops provision key; Chris confirm Ph2 gate

**Loadstar Holdings TX LLC:**
- Master acquisition holding company for all deals (Chris's decision 2026-06-23)
- Formation via SOSDirect pending confirmation of registration completion
- First intended use: Colorado Springs Defense IT contractor deal (when LOI advances)
- **Action:** confirm SOSDirect registration status

### Shared Scripts
- **NT8 pipeline health check**: `/home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/nt8-pipeline-check.sh` — cron 12:00 UTC Mon-Fri (devops config). Alerts Chris via Telegram if `strategy_states` most recent record is >2h stale before pre-market open. Root fix for blind H137 windows caused by MonkeyAttackMonitor stopping on NT8 Windows VPS.
- `scripts/h137-premarket-check.sh` — H137 pre-market check 13:15 UTC (9:15 ET): verifies PAAPEX pipeline fresh + state=Active; RED→fable-reviewer+chief+Chris
- **Trade query helper**: `/home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/query-trades.sh`
  - Local agents hit DB directly: `postgresql://orbfutures:orbfutures@127.0.0.1/orbfutures_dashboard`
  - `bash query-trades.sh today` — today's completed trades with CT times, P&L, exit reason, VIX regime
  - `bash query-trades.sh open` — open positions (**NOTE: DB upload lag means this may not reflect positions entered in the last ~5-10 min. For real-time confirmation, ask Chris to check NT8 directly.**)
  - `bash query-trades.sh summary` — P&L by account
  - `bash query-trades.sh account <id>` — single account detail
  - `bash query-trades.sh recent [N]` — last N trades
  - Key tables: `trades`, `mov_sessions`, `strategy_states`, `accounts`, `daily_summaries`

### NT8 Strategy Status — How to Check (NEVER ask Chris where to find this)

All NT8 live data flows into the orbfutures dashboard DB. Query it directly — do not ask Chris.

```bash
# Live strategy states (current regime, position, last update)
psql postgresql://orbfutures:orbfutures@127.0.0.1/orbfutures_dashboard \
  -c "SELECT account_id, strategy_name, regime, position, updated_at FROM strategy_states ORDER BY updated_at DESC LIMIT 20;"

# Check staleness (flag if updated_at > 2h ago during market hours)
psql postgresql://orbfutures:orbfutures@127.0.0.1/orbfutures_dashboard \
  -c "SELECT account_id, strategy_name, updated_at, now() - updated_at AS age FROM strategy_states ORDER BY age DESC;"

# Open positions right now
bash /home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/query-trades.sh open

# Today's closed trades
bash /home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/query-trades.sh today

# HolyGrail terminal logs (NT8 VPS)
# SSH: maprod — logs at ~/repos/ on remote
# Dashboard upload target: dashboard.profithits.app
```

**Rule:** If you need NT8/strategy data, query the DB or use query-trades.sh. Never ask Chris where data lives — it is always in the DB above.
- **CT Time utility** (fleet standard, P1 directive 2026-06-22): `/home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/ct-time.sh`
  - All Telegram messages to Chris must use Central Time (CDT/CST), never UTC
  - `bash ct-time.sh ts` → `Mon Jun 22 9:23 AM CDT` (Telegram format)
  - `bash ct-time.sh from-utc HH:MM` → converts UTC to CT string
  - `bash ct-time.sh [now|time|date|dow|offset|dst|abbr]`
  - DST-aware: CDT (UTC-5) Apr–Oct, CST (UTC-6) Nov–Mar

## Key Links

- **Trade Dashboard**: dashboard.profithits.app (NinjaTrader trade data upload target)

## Decisions Log

- 2026-04-07: Setting up cortextOS to automate prop firm account management - manual tracking doesn't scale with growing account count

## Infrastructure Overview (updated 2026-04-07)

The system manages prop firm trading accounts across multiple vendors with connected infrastructure:

### Architecture
- **Windows VPS**: NinjaTrader strategy deployment (live trading)
- **Linux VPS (build)**: Claude Code builds and maintains the strategy code
- **Linux VPS (monitoring)**: Monitoring addon uploads data here

### Core Operations
- Monitor all VPS instances are running and synced
- Rotate blown accounts and purchase new ones
- Correlate risk based on news events
- Generate performance reports to validate strategies
- Watch for billing issues across vendors
- Track account lifecycle: eval → funded → active → failed/archived

### Vendors
- NinjaTrader (trading platform)
- Various prop firm vendors (account purchases)
- VPS providers (Windows + Linux instances)

---

## Sharing files with Chris — files.profithits.app

This is the **fleet-wide standard** for sharing markdown reports, image previews, video deliverables, or any file with Chris. All current and future agents in this org should use this — do not paste large content into Telegram, do not email attachments, do not stand up ad-hoc HTTP servers.

### Why
- Persistent: tokens are permanent (no expiry), so the URL stays valid until the secret rotates.
- Trivial to mint: one bash helper, no auth flow on the agent side.
- Native rendering: markdown → HTML, mp4 → range-streamed video (scrubbing works), other files served with correct mime.
- Locked down: HMAC-SHA256 token check + path-traversal protection + 127.0.0.1-only origin behind Cloudflare.

### How
1. **Put the file under `/mnt/r2/files/`** (R2-backed, every agent on this box can write here):

   ```bash
   mkdir -p /mnt/r2/files/$CTX_AGENT_NAME
   cp my-report.md /mnt/r2/files/$CTX_AGENT_NAME/2026-04-26-incident-response.md
   ```

2. **Mint a URL** with the helper. The path passed in is RELATIVE to `FILES_ROOT` (`/mnt/r2/files`):

   ```bash
   /home/claude-dev/preview-server/scripts/mint-preview-url.sh \
     $CTX_AGENT_NAME/2026-04-26-incident-response.md
   # → https://files.profithits.app/preview/<12hex>/<agent>/2026-04-26-incident-response.md
   ```

3. **Send the URL** wherever — Telegram to Chris, agent message, knowledge note, post-mortem, etc.

### File-type behaviour
| Extension | Rendering |
|---|---|
| `.md`, `.markdown` | Parsed via `marked`, served as HTML with Inter font + dark/light mode auto-detect + code-block styling |
| `.mp4`, `.webm`, `.mov`, `.m4v` | Streamed with `Accept-Ranges: bytes`. Scrubbing works in Safari and Chrome. |
| anything else | Raw bytes with mime-type lookup + `Content-Disposition: inline` |

### Path layout convention
`<agent>/<YYYY-MM-DD>-<short-name>.<ext>` — so things stay discoverable per-agent and chronologically sortable.

### Hard rules
- **No secrets in `/mnt/r2/files/`.** A signed URL is one share away from anyone who clicks it. Treat the bucket as eventually public.
- **Stay in your agent's namespace.** Write to `/mnt/r2/files/<your-agent>/...`; don't litter the root.
- **Don't call the preview-server directly.** It binds 127.0.0.1; nginx proxies through Cloudflare via `https://files.profithits.app/preview/...`. Always use the helper.
- **Tokens are permanent.** If a URL leaks to someone you didn't intend to share with, the only cure is rotating `PREVIEW_SECRET` on maprod (which invalidates every minted URL across the fleet).

## Telegram Inline Keyboard Decisions

Use `cortextos bus send-decision` to send tappable button decisions to Chris instead of asking text questions. **Always use this for any YES/NO, pick-one-of-N, or approval choice.**

```bash
# Binary decision
cortextos bus send-decision "$CTX_TELEGRAM_CHAT_ID" \
  "Title (one line)" \
  "Context — what this is about, what each option means" \
  --options "YES,NO" \
  --agent "$CTX_AGENT_NAME"

# Multi-option
cortextos bus send-decision "$CTX_TELEGRAM_CHAT_ID" \
  "Which cover path" \
  "A = use existing, B = regenerate, C = hold" \
  --options "A - Use existing,B - Regenerate,C - Hold" \
  --agent "$CTX_AGENT_NAME"

# Check status
cortextos bus list-decisions --status pending
cortextos bus list-decisions --status resolved
```

Defaults: `--options "YES,NO,HOLD"`. State survives restarts (pending-decisions.json). One send-decision per item — do not batch multiple choices into one message. Commit 1fd4715.

---

## Knowledge Base (KB) — Fleet Behavior Notes

### kb-ingest timeout floor: 90 seconds minimum

`cortextos bus kb-ingest` spawns a Python subprocess that imports chromadb. On this VPS, the import alone takes **17-20s** (hnswlib native load + posthog init). Add embedding time for typical memory files and the safe minimum timeout is **90s**.

```bash
# Always use at least 90s timeout when wrapping kb-ingest
timeout 90 cortextos bus kb-ingest ./MEMORY.md ./memory/$(date -u +%Y-%m-%d).md \
  --org $CTX_ORG --agent $CTX_AGENT_NAME --scope private --force
```

Using 45-60s timeouts will cause false failures on routine memory ingests.

### 03:00 UTC kb-ingest hangs — IPv6 posthog stall (self-resolving)

Overnight kb-ingest calls may hang 30-60s longer than normal around 03:00 UTC. Root cause: VPS IPv6 is intermittently dead (reference_vps_ipv6_flaky); chromadb attempts an IPv6 AAAA DNS lookup for posthog telemetry on startup and stalls when IPv6 is unreachable. Telemetry is already disabled via env var but the DNS attempt still fires. This clears on its own as IPv6 flaps back — no action needed, no code change required. If an ingest times out at 03:00 UTC, retry once; second attempt typically succeeds.

### Postgres timezone boundary: correct UTC-equivalent of local midnight

`CURRENT_DATE AT TIME ZONE 'America/Chicago'` is WRONG — postgres treats `CURRENT_DATE` as UTC midnight then converts backward to Chicago, producing 19:00 UTC (7 PM prior day in CDT). Fills in the last 2h of UTC-yesterday pass the filter.

**Correct pattern:**
```sql
timestamp >= DATE_TRUNC('day', NOW() AT TIME ZONE 'America/Chicago') AT TIME ZONE 'America/Chicago'
```
This: (1) takes NOW() in Chicago time, (2) truncates to midnight Chicago, (3) converts back to UTC timestamptz (05:00 UTC in CDT). Use this anywhere a "current session" or "today CT" boundary is needed. (ee93537, 2026-07-17)
