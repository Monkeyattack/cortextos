---
name: deal-workup
description: "Run a full M&A deal workup on a business listing. Dispatches parallel research agents, produces 6 deliverables (deal book, market analysis, LOI + diligence list, investor pitch deck, one-page teaser, capital stack + returns model), mints each as a shared URL, and delivers tight headline + links. Owner: pm methodology; mechanics: devops."
triggers: ["run a deal workup", "full workup", "deal workup on", "workup on", "run workup", "acquisition analysis", "do a workup", "deal analysis on", "vetting pass", "sheet vetting"]
---

# deal-workup Skill

Full M&A deal workup pipeline. Produces 6 investor-grade deliverables from a single listing input. Always spawn workers for research — NEVER run research inline.

**Canonical reference deliverables (gold-standard format):**
- Deal book: https://files.profithits.app/preview/8f440eb32b88/pm/2026-06-04-dealbook-2-marketing-agency.md
- Market analysis + growth paths: https://files.profithits.app/preview/0190b35aab1f/pm/2026-06-04-agency-market-analysis-growth-paths.md
- LOI + diligence: https://files.profithits.app/preview/bb72928e56b5/pm/2026-06-04-agency-LOI-and-diligence.md
- Pitch deck (markdown): https://files.profithits.app/preview/950f39e035e0/pm/2026-06-04-agency-investor-pitch-deck.md
- Pitch deck (designed HTML): https://files.profithits.app/preview/5a193eaa23c2/pm/2026-06-04-agency-pitch-deck.html
- One-page teaser (designed HTML): https://files.profithits.app/preview/e325fed25d81/pm/2026-06-04-agency-investor-teaser.html

---

## HOUSE RULES — MANDATORY, CHECK BEFORE EVERY DELIVERABLE

1. **Financing section goes at the TOP of every deal book** — immediately after the snapshot block, before any other section.
2. **Listing link slot** — every doc header gets a `🔗 Listing:` field. NEVER fabricate a broker URL or a files.profithits.app preview URL. If the listing is gated (Quiet Light etc.) and you only have pasted text, ask the user for the broker link before composing docs. Mint preview URLs ONLY after the mint helper returns the real token.
3. **Designed HTML deliverables** — single self-contained HTML files. No external fonts; use system font stacks (e.g. `-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif`). Anti-AI-slop: NO purple gradients, NO Inter, NO center-everything. Verify HTTP 200 + correct content-type before sending.
4. **Financial disclaimers** — all financials labeled: *"Illustrative / pre-tax / seller-reported — confirm via Q-of-E."* Investor docs must include: *"Not an offer of securities; counsel to paper any raise."*
5. **Operator PG promote** — the operator who personally guarantees the SBA loan gets an equity promote above capital share. Investors do NOT take the PG. Default investor terms: 8% preferred return + operator-favorable split. Encode this in every capital stack and pitch deck.
6. **Telegram messaging** — use single-quoted bash strings for any message containing dollar amounts. Send tight headline + minted URL pointer ONLY — no inline content dumps.
7. **Parallel research** — dispatch all 3 research agents concurrently via `cortextos spawn-worker`. Cap concurrency per quota. Never run research inline. **Cap each worker's OWN research depth in its prompt** (e.g. "≤3 web searches; do NOT spawn your own sub-agents"). Uncapped workers that recursively fan out into large research swarms trip a server-side rate limit ("Server is temporarily limiting requests — not your usage limit") that kills them AND sibling workers mid-run (caught 2026-06-15: one worker fanned to ~80 sub-agents, killed itself + a sibling).
8. **Mint protocol** — run `bash /home/claude-dev/preview-server/scripts/mint-preview-url.sh <path>`, read the returned token, then compose the URL. Never guess tokens. Token is deterministic per filepath — re-run mint to recover if lost.

---

## TRIGGER / INPUT PARSING

**Triggers:** "run a deal workup on X", "full workup", dispatched after a sheet-vetting pass.

**Inputs — parse before proceeding:**
- **Required:** business listing — URL OR pasted seller summary text
  - If a URL is provided and the site is likely gated (Quiet Light, Flippa private, Empire Flippers private listing): attempt fetch; if 403/blocked, ask the user to paste the listing text and provide the broker link separately. Do NOT fabricate.
- **Optional:**
  - Which deliverables to produce (default = all 6)
  - Buyer profile / investment thesis
  - Target raise / structure preferences (e.g. "SBA only", "equity-only", "co-investor needed")

---

## STAGE 0 — INTAKE & SCREEN

Parse the listing and compute:

```
SDE_MULTIPLE   = Asking Price ÷ SDE (or Seller's Discretionary Earnings)
REV_MULTIPLE   = Asking Price ÷ Annual Revenue
MARGIN         = SDE ÷ Annual Revenue × 100
```

Flag the headline vs. asset-class norms:
- **Cheap:** SDE multiple meaningfully below category median (e.g. <3x for service businesses, <2x for e-commerce)
- **Fair:** Within +/- 0.5x of category median
- **Rich:** Above median — note what the premium is pricing in (growth, defensibility, platform)

If this is part of a multi-listing sheet, run a **vetting/tiering pass** first:
- **Pursue** — strong unit economics, clean story, reasonable ask
- **Watch** — interesting but one concern blocks immediate move
- **Pass** — structural problem (key-person cliff, declining revenue, ask too rich)

Also compute the **quick-vet 0–100 score** (deterministic rubric in quick-vet SKILL.md §5: multiple vs norm 30 / revenue trend 20 / industry risk 15 / owner dependency 15 / deal type 10 / ask stated 10) and its rating: **STRONG (≥70) / WATCHLIST (45–69) / PASS (<45)** with a 1-sentence rationale. If the deal arrived from a `deal-flow-scan` digest it already has a score — reuse it, re-scoring only if the listing adds material new facts.

Produce a brief intake summary (internal, not a deliverable):
```
Business: [name / category]
Asking: $X | SDE: $Y | Revenue: $Z
SDE Multiple: Xx | Rev Multiple: Xx | Margin: X%
Headline: CHEAP / FAIR / RICH
Score: NN/100 — STRONG / WATCHLIST / PASS — [1-sentence rationale]
Tier: PURSUE / WATCH / PASS
Listing URL: [from user, or PENDING]
```

Carry the score + rating into the deal book's **Verdict** section.

---

## STAGE 0.5 — INDUSTRY PROFILE FETCH (INDUSTRY CONTEXT)

**Run this BEFORE dispatching the analysis/research workers and before any final analysis prompt.** It grounds every downstream worker and deliverable in real sector data (BizScout data moat).

Determine the deal's **NAICS code** (from the listing category — map to the closest 6-digit NAICS) and its **U.S. state** (from the business location; if the business is national/online, use the state of incorporation or HQ). Then spawn the Industry Profile worker:

```bash
python /home/claude-dev/repos/industry-profile/industry_profile_worker.py \
  --naics <NAICS_CODE> --state <STATE_ABBR> > /tmp/industry_profile_<slug>.json
echo "exit=$?"
```

- Exit `0` → read `/tmp/industry_profile_<slug>.json` and parse it as the `industry_profile` object (schema + 30-day-cached behavior documented in the `industry-profile` skill).
- Exit `1` (or unparseable JSON) → log it and proceed WITHOUT industry context. The workup is never blocked by a missing profile.

**Inject the profile as `INDUSTRY CONTEXT`** into each Stage 1 worker prompt (substitute alongside the other `{PLACEHOLDERS}`), e.g. prepend a block:

```
INDUSTRY CONTEXT (BizScout industry_profile — NAICS {naics_label}, {location}):
- Industry size est: {industry_size_est}
- 3yr employment growth: {growth_rate_3yr_employment} | sector revenue growth: {growth_rate_sector_revenue}
- Public-peer avg EBITDA margin: {avg_ebitda_margin_public_peers} | SMB margin adj: {smb_margin_adj}
- Competitive density: {competitive_density} | life-cycle stage: {life_cycle_stage}
- Risk factors: {risk_factors}
- 5yr outlook: {outlook_5yr} | confidence: {confidence} | freshness: {data_freshness}
Use this as the factual baseline; do NOT contradict it. Any field equal to "unavailable" must be treated as unknown — research it, never present it as a datapoint.
```

Worker A (Market + Valuation) and Worker C (Market Deep-Dive + Growth) benefit most — the public-peer margin and competitive-density signals anchor the valuation verdict and the growth-play feasibility. Carry the same INDUSTRY CONTEXT into the deal book's Business & Market and Valuation sections.

---

## STAGE 1 — PARALLEL RESEARCH DISPATCH

Spawn **3 workers concurrently** using `cortextos spawn-worker`. Do not proceed to Stage 2 until all 3 return.

Prompt templates live in `references/` alongside this SKILL.md. Substitute all `{PLACEHOLDERS}` before dispatch.

### Required substitutions

| Placeholder | Value from Stage 0 |
|---|---|
| `{BUSINESS_DESC}` | One-line business description: category, geography, size, headcount |
| `{ASKING_PRICE}` | Full asking price string (e.g. "$5,100,000") |
| `{SDE}` | SDE string (e.g. "$1,200,000") |
| `{ASKING_MULTIPLE}` | Computed SDE multiple (e.g. "4.25x") |

### Worker A — Market + Valuation
**Prompt template:** `references/market-valuation-prompt.md`
**Output:** Market sizing, comp multiples, valuation verdict

### Worker B — Financing + Deal Structure + Risk
**Prompt template:** `references/financing-risk-prompt.md`
**Output:** SBA 7(a) sizing, capital stack, risk register

### Worker C — Market Deep-Dive + Growth Strategy
**Prompt template:** `references/market-growth-prompt.md`
**Output:** Industry dynamics, AI/disruption angle, 5–8 ranked growth plays

**Dispatch pattern:**
```bash
# Spawn all 3 concurrently — do not wait for one before starting next
cortextos spawn-worker "deal-workup-valuation-$(date +%s)" \
  --dir /home/claude-dev/cortextos/orgs/prop-firm-admin \
  --prompt "<Worker A prompt with substitutions>"

cortextos spawn-worker "deal-workup-financing-$(date +%s)" \
  --dir /home/claude-dev/cortextos/orgs/prop-firm-admin \
  --prompt "<Worker B prompt with substitutions>"

cortextos spawn-worker "deal-workup-growth-$(date +%s)" \
  --dir /home/claude-dev/cortextos/orgs/prop-firm-admin \
  --prompt "<Worker C prompt with substitutions>"
```

> **Note:** The running agent may alternatively dispatch research workers via the Agent tool (subagent spawn) — that is how pm ran it live and is equally valid. Use whichever path the current execution environment supports.

Collect all 3 outputs before proceeding.

---

## STAGE 2 — DELIVERABLES

Produce all 6 deliverables (or the subset requested). Each is written to disk, minted, and URL recorded before the next is started.

**File naming convention:** `pm/YYYY-MM-DD-<slug>-<type>.md` (or `.html`)
**Mint command:** `bash /home/claude-dev/preview-server/scripts/mint-preview-url.sh <path>` — read returned token, compose URL. Never guess.

---

### Deliverable 1 — Deal Book (markdown)

**Sections in order (MANDATORY):**
```
# Deal Book: [Business Name]
🔗 Listing: [broker URL — ask user if not provided; do NOT fabricate]
_[Date] | [Agent] | Confidential — not for distribution_

---

## Snapshot
| Field | Value |
|---|---|
| Business | ... |
| Category | ... |
| Location | ... |
| Asking Price | $X |
| SDE (TTM) | $Y |
| Revenue (TTM) | $Z |
| SDE Multiple | Xx |
| Employees | N |
| Years Operating | N |

## Financing ← MUST BE SECOND, IMMEDIATELY AFTER SNAPSHOT
(from Worker B output: SBA sizing, capital stack, DSCR)

## Central Question
(the one thesis-defining question this deal hinges on)

## Business & Market
(from Worker A + C outputs)

## Valuation
(from Worker A: comp multiples, verdict)

## Risk Register
(from Worker B: full risk table)

## Diligence Asks
(top 10–15 items to request at LOI stage)

## Verdict
PURSUE / WATCH / PASS + 2–3 sentence rationale

---
_Illustrative / pre-tax / seller-reported — confirm via Q-of-E._
```

---

### Deliverable 2 — Market Analysis + Growth Paths (markdown)

Use Worker C output verbatim as the base. Add a header block:
```
# Market Analysis + Growth Paths: [Business Name]
🔗 Listing: [broker URL]
_[Date] | [Agent]_
```

Ensure the growth plays table is present and ranked. Label all financials ILLUSTRATIVE.

---

### Deliverable 3 — LOI + Diligence Request List (markdown)

**Sections:**
```
# Letter of Intent + Diligence Checklist: [Business Name]
🔗 Listing: [broker URL]
_Non-binding. Counsel to review before submission._

## Non-Binding Letter of Intent

[Date]

To: [Seller / Broker name if known, else "Seller"]
Re: Indication of Interest — [Business Name]

Dear [Seller],

This letter sets forth the non-binding terms under which [Buyer Entity] ("Buyer") proposes to acquire [Business Name] ("Company").

**Proposed Purchase Price:** $[X]
**Structure:** Asset purchase / Stock purchase (TBD pending diligence)
**Financing:** SBA 7(a) loan + equity injection + [seller note if applicable]
**Deposit:** $[X] earnest money within [N] days of LOI execution
**Exclusivity:** [45–60] days from LOI execution
**Due Diligence Period:** [30–45] days
**Contingencies:** Financing, satisfactory Q-of-E, lease assignment, key employee retention
**Closing Target:** [X] days post-exclusivity

This LOI is non-binding and for discussion purposes only. Either party may withdraw at any time. Counsel to paper definitive agreements.

Signed: _______________   Date: _______________

---

## Diligence Request List

_Categorized. Items marked [COUNSEL] should be reviewed by transaction attorney before submission._

### Financial
- [ ] 3 years P&L (GAAP or cash basis; note which)
- [ ] 3 years tax returns (business + personal if sole prop/S-Corp)
- [ ] Trailing 12-month P&L + YTD current year
- [ ] SDE reconstruction / add-back schedule
- [ ] Accounts receivable aging
- [ ] Accounts payable schedule
- [ ] Monthly revenue by customer (trailing 24 months)

### Legal [COUNSEL]
- [ ] Corporate formation docs + ownership cap table
- [ ] All material contracts (customers, vendors, leases)
- [ ] Pending or threatened litigation
- [ ] IP ownership (trademarks, patents, proprietary systems)
- [ ] Employee agreements + non-competes

### Operations
- [ ] Org chart + key employee bios
- [ ] Customer concentration analysis (top 10 customers = % of revenue)
- [ ] Vendor concentration (top 5 suppliers = % of COGS)
- [ ] Systems/software stack + license transferability
- [ ] Facilities: lease terms, renewal options, landlord consent to assignment

### HR
- [ ] Payroll register (last 12 months)
- [ ] Benefits schedule
- [ ] Any PEO or EOR arrangements

### Real Estate / Equipment
- [ ] Lease(s) with all amendments
- [ ] Equipment list + condition + age
- [ ] Any deferred maintenance or capex needs

_[COUNSEL] items require attorney review prior to submission. Not an offer of securities._
```

---

### Deliverable 4 — Investor Pitch Deck (markdown, slide-structured)

**Format:** Each `##` heading = one slide. Keep slides tight — bullet points only, no paragraphs.

```
# [Business Name] — Acquisition Opportunity
_[Date] | Confidential | Not an offer of securities — counsel to paper any raise_

## The Opportunity
- Category + geography
- Asking: $X | SDE: $Y | Xx SDE multiple
- Verdict: [CHEAP / FAIR / RICH + one-line why]

## Business Snapshot
- N years operating | N employees
- Revenue: $Z TTM | SDE: $Y TTM | Margin: X%
- Customer base: [concentration note]

## Market
- TAM: $X | CAGR: X% (source)
- Key tailwind: [one line]
- Defensibility: [one line]

## Growth Plays (Top 3)
| Play | Est. Y1 Uplift | Capex |
|---|---|---|
| 1. [Play] | $X–$Y | $Z |
| 2. [Play] | $X–$Y | $Z |
| 3. [Play] | $X–$Y | $Z |

## Deal Structure
- Total project cost: $X
- SBA 7(a): $X (X%) | Equity injection: $X (X%) | Seller note: $X (X%)
- Annual debt service: $X | DSCR: X.Xx
- Operator PG: Operator guarantees SBA loan → equity promote above capital share

## Investor Terms
- Preferred return: 8% cumulative
- Split above pref: operator-favorable — default **~60–70% operator / 30–40% investors** (promote reflects sourcing + operating + the SBA personal guarantee the operator carries alone)
- Waterfall: 8% pref → return of investor capital → operator/investor split
- Distributions: [quarterly / per cash flow]
- Target hold: [3–5 years]
- Exit: strategic sale or recap

## Returns Model (Illustrative)
| Scenario | Y3 SDE | Exit Multiple | Equity Value | CoC Return |
|---|---|---|---|---|
| Base | $Y | Xx | $X | Xx |
| Upside | $Y | Xx | $X | Xx |
| Downside | $Y | Xx | $X | Xx |

## Diligence Timeline
- LOI → exclusivity: [N days]
- Q-of-E + legal: [N days]
- SBA processing: [45–90 days]
- Target close: [date]

## Team
- Operator: [name / placeholder]
- Advisors: [deal counsel, SBA lender, accountant]

---
_Illustrative / pre-tax / seller-reported — confirm via Q-of-E. Not an offer of securities; counsel to paper any raise._
🔗 Listing: [broker URL]
```

---

### Deliverable 5 — One-Page Investor Teaser (designed HTML)

**Rules:**
- Single self-contained HTML file — no external fonts, no CDN links
- System font stack: `-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica Neue, sans-serif`
- NO purple gradients. NO Inter. NO center-everything.
- Clean, print-ready layout (A4/Letter). Think executive memo, not pitch theater.
- 60-second pre-NDA version — no confidential financials; just the hook.

**Sections:**
1. Header: Business name + tagline + asking price range (can be rounded/obscured)
2. Why This Business (3 bullets)
3. Opportunity Snapshot (category, geography, size, years operating)
4. Growth Angle (1–2 sentences)
5. Contact / Next Steps
6. Footer: "Pre-NDA teaser. For qualified buyers only. Not an offer of securities."
7. `🔗 Listing: [broker URL]` in footer

Verify HTTP 200 + `Content-Type: text/html` on the minted URL before delivering.

---

### Deliverable 6 — Capital Stack + Returns Model (designed HTML)

**Rules:** Same HTML self-containment rules as Deliverable 5.

**Sections:**
1. Header: Business name + deal date
2. Capital Stack Table: SBA loan / equity injection / seller note / total — with % of total
3. Debt Service: monthly payment, annual debt service, DSCR at asking
4. Cash-on-Cash Returns by year (Y1–Y5 base case)
5. Equity Build: balance sheet equity at Y1, Y3, Y5 (assuming debt paydown + SDE growth)
6. Exit Multiple Expansion: exit at Xx vs. Nx multiple — equity value table
7. Investor Terms block: 8% pref + operator split
8. Operator PG note: "Operator personally guarantees SBA loan — equity promote reflects PG risk not shared by investors"
9. Recoup time: years to recover equity injection from cash-on-cash
10. Footer disclaimer: _Illustrative / pre-tax / seller-reported — confirm via Q-of-E. Not an offer of securities._
11. `🔗 Listing: [broker URL]`

Verify HTTP 200 + `Content-Type: text/html` before delivering.

---

## STAGE 3 — DELIVER & LOG

### 1. Collect all minted URLs

After each deliverable is minted, record the URL in a local scratch list. Do not send until all requested deliverables are minted.

### 2. Send Telegram message

Use **single-quoted bash** for any message containing dollar amounts.

Format:
```
Deal workup complete: [Business Name] ([SDE multiple]x SDE, $[asking])

Deal book: <url>
Market + growth: <url>
LOI + diligence: <url>
Pitch deck (md): <url>
Pitch deck (HTML): <url>
Teaser: <url>
Capital stack: <url>
```

Send via: `cortextos bus send-telegram $CTX_TELEGRAM_CHAT_ID '<message>'` (single quotes — required for $ amounts).

### 3. Create and complete task

```bash
TASK_ID=$(cortextos bus create-task "Deal workup: [Business Name]" \
  --desc "Full workup on [business] at [asking price]")
cortextos bus complete-task $TASK_ID --result "6 deliverables minted. Deal book: <url>"
```

### 4. Ingest to shared KB

```bash
# Write the deal book to disk first, then ingest the file path
cortextos bus kb-ingest pm/YYYY-MM-DD-dealbook-<slug>.md \
  --org $CTX_ORG \
  --agent $CTX_AGENT_NAME \
  --scope shared
```

### 5. Link artifacts to the deal record (MANDATORY — populates the deals dashboard)

The deals board (`deals.profithits.app`, API `localhost:3201`) renders `dealbook_url`, `loi_url`, `deck_url` on each deal's detail page and has an edit form for them — but **nothing populates them unless this step runs.** Minting a file is NOT enough; you MUST PATCH the minted URLs back onto the deal record, or the deal shows blank artifacts (caught 2026-06-24, Chris flagged deal #198 dealbooks not populating).

```bash
# Find the deal id on the board (by listing_url if present, else by name)
DEAL_ID=$(curl -s "http://localhost:3201/api/deals?search=<name-or-listing>" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")

# PATCH the minted artifact URLs onto the record (only the ones produced)
curl -s -X PATCH "http://localhost:3201/api/deals/$DEAL_ID" \
  -H "Content-Type: application/json" \
  -d '{"dealbook_url":"<deal-book url>","loi_url":"<LOI url>","deck_url":"<pitch-deck-HTML url>"}'
```

Map: **dealbook_url** = Deliverable 1 (deal book) · **loi_url** = Deliverable 3 (LOI + diligence) · **deck_url** = Deliverable 5/4 (pitch deck HTML, else markdown). Omit any field not produced. Verify the deal detail page renders the links after PATCH.

> If the deal isn't on the board yet, upsert it first via `POST /api/deals/ingest` (which also accepts `dealbook_url`/`loi_url`/`deck_url` directly), then PATCH for updates.

---

## LOOP PM FOR — What Goes Back vs. What You Handle

**Route to pm (do not decide yourself):**
- Whether to submit the LOI (Pursue → LOI = pm + Chris decision)
- Buyer profile / thesis changes that affect structure
- Analytical template tweaks (new sections, changed disclaimer language, different returns model assumptions)
- Whether to engage a specific SBA lender or deal attorney
- Any finding that materially changes the tier (e.g. discover customer concentration >60% mid-workup)
- Investor terms changes (different pref rate, different split)

**Handle autonomously (running agent decides):**
- Placeholder values for buyer name / entity if not provided (use "[Buyer]")
- HTML layout and styling choices within house rules
- Order of growth plays in Deliverable 2 (rank by impact × feasibility ÷ risk as instructed)
- Formatting, file naming, mint/delivery mechanics
- Retry if a worker 403s (re-prompt with pasted text)
- If listing URL is gated: ask user for broker link, proceed with pasted text in the interim

---

## QUICK REFERENCE — Mint + Send Pattern

```bash
# 1. Write file to /mnt/r2/files/<agent>/ (FILES_ROOT=/mnt/r2/files)
#    e.g. write to /mnt/r2/files/pm/YYYY-MM-DD-slug-type.md
#    (produce the deliverable markdown or HTML to that path)

# 2. Mint using RELATIVE path (relative to FILES_ROOT)
#    NEVER guess the token — read it from stdout
TOKEN_LINE=$(bash /home/claude-dev/preview-server/scripts/mint-preview-url.sh pm/YYYY-MM-DD-slug-type.md)
# TOKEN_LINE contains the real token — read it, do NOT fabricate

# 3. Compose the full preview URL from the returned token:
#    https://files.profithits.app/preview/<token>/pm/YYYY-MM-DD-slug-type.md
#    Token is deterministic per filepath — re-run mint to recover if lost, never guess.

# 4. Verify (for HTML deliverables)
curl -sI <url> | grep -E "HTTP|content-type"

# 5. Send (single quotes for $ amounts)
cortextos bus send-telegram $CTX_TELEGRAM_CHAT_ID '<message with URLs>'
```

---

_Skill owner: pm (analytical content) / devops (mechanics). Last updated: 2026-06-04._
