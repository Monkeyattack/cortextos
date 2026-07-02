---
name: gmail
description: "General Gmail/mailbox skill for the fleet — a cheap mechanical scan/extract/act wrapper. Caller supplies a Gmail query, a time window, and an extraction schema; this skill searches the mailbox, pulls schema-defined fields from each thread, and can label/archive threads. No judgment, no vetting — pure search → extract → act. Auth failures are reported loudly, never as empty results. Owner: prop-firm-admin (devops mechanics)."
triggers: ["scan my gmail", "search my inbox", "extract from email", "pull fields from gmail", "label this thread", "archive this email", "gmail skill", "mailbox scan"]
---

# gmail Skill

A thin, mechanical wrapper over the `meredith@monkeyattack.com` mailbox. Intended to be invoked by a **cheap (Haiku) sub-agent** that does one job: take a query + schema, return structured rows. It does NOT vet, rank, or interpret deals/messages — that judgment belongs to the *caller* (e.g. `deal-flow-scan`).

**Do not rebuild auth.** Read/search goes through `gmail_search.py` (Vault service account). Send/archive/label goes through the `gog` CLI (already configured). Neither needs setup here.

---

## INTERFACE CONTRACT

**Caller provides (in the invocation prompt):**

| Field | Type | Meaning |
|---|---|---|
| `query` | string | A Gmail search string, e.g. `to:foo@bar.com newer_than:1d`. Passed verbatim to `gmail_search.py --query`. |
| `window` | string | A `newer_than:Nd` clause. The caller may fold this into `query` or pass it separately; if separate, append it to the query. |
| `extraction_schema` | JSON object | `{ "<field>": "<description of what to pull and from where>", ... }`. One key per field to extract from each thread. |

**Skill returns (exact shape):**

```json
{
  "status": "ok" | "auth_error",
  "threads_scanned": N,
  "results": [
    { "<field>": "<extracted value or null>", ... , "thread_id": "<id>", "subject": "<subject>" }
  ]
}
```

- `threads_scanned` = the script's `thread_count` (the script field is named `thread_count`; map it to `threads_scanned` in the return).
- `results` has one object per thread (or per deal-block, if the caller's schema implies multiple per thread — e.g. a newsletter with ~5 deals; in that case emit one row per block and repeat `thread_id`/`subject`).
- Always include `thread_id` and `subject` on every row so the caller can `label`/`archive` later.

**AUTH FAILURES — REPORT LOUDLY:**

> If `gmail_search.py` returns `status: "auth_error"`, **return `{ "status": "auth_error", "threads_scanned": 0, "results": [], "error": "<message from script>" }` and STOP.**
> NEVER return `status: "ok"` with empty `results` when the real cause was an auth failure. `status: "ok"` + `threads_scanned: 0` means *genuinely no matching threads* — that is a valid, honest result. The two cases must never be conflated.

---

## OPERATIONS

### 1. search(query, window) → threads JSON

Invoke `gmail_search.py` exactly as `deal-flow-scan` Stage 1a does. `VAULT_TOKEN` is **not** in any agent `.env` — source it from `~/.vault-token` (the vault CLI default token file):

```bash
VAULT_TOKEN=$(cat ~/.vault-token) \
/home/claude-dev/repos/social-sync/venv/bin/python3 \
  /home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/gmail_search.py \
  --query "<QUERY> <WINDOW>" \
  --max-results 50 --format full > /tmp/gmail-scan-$(date -u +%Y%m%d-%H%M%S).json
```

- Always use `--format full` when extraction is needed — it returns each thread's plaintext inline as `body_text` (no separate fetch).
- Raise `--max-results` for wide windows (e.g. `--max-results 200` for `newer_than:90d`).
- The script output schema:

```json
{ "status": "ok", "thread_count": N,
  "threads": [ { "id": "...", "thread_id": "...", "subject": "...", "from": "...", "date": "...", "body_text": "<full plaintext>" } ] }
```

- `id` and `thread_id` are the same value — the script emits both (since 2026-07-02) so consumers reading either field name work. If the first message of a thread has an empty body, the script now falls back to later messages automatically.

**Check `status` first.** Non-`ok` statuses: `auth_error` (creds/SA delegation) and `search_error` (bad query / API failure — since 2026-07-02). For EITHER, follow the loud-failure rule above and stop — return the status verbatim so the caller can report the right cause; never disguise either as empty results.

### 2. extract(threads, schema) → structured fields per thread

For each thread, read `subject` + `body_text` and pull one value per `extraction_schema` key:

- Use each schema field's **description** as the instruction for what/where to pull.
- **Prefer literal values over inferred** — if the email says `Asking: $1.2M`, return `"$1.2M"` (or `1200000` only if the schema description asks for a number); do not estimate, normalize, or invent.
- **`null` if not present** — never fabricate. Especially never fabricate URLs (return the literal link from the body, or `null`).
- If a schema description says "extract from subject" (e.g. a `<City>-Based` pattern), read the `subject` field, not the body.
- If the caller's schema implies multiple records per email (a newsletter with N listings), split `body_text` into blocks and emit one `results` row per block, repeating `thread_id` + `subject`.

Extraction is an LLM read of `subject` + `body_text` — no grep gymnastics required. The schema descriptions are the contract; follow them literally.

### 3. label(thread_id, label) → tag a thread

Route to the workspace agent — do NOT shell out to `gog` (not installed) or call MCP Gmail directly from this skill:

```bash
cortextos bus send-message workspace normal '{"action":"label","thread_id":"<thread_id>","label":"<label_name>"}'
```

The workspace agent owns all Gmail write operations (label/archive) via MCP.

### 4. archive → label `deal-ingested` workaround

MCP Gmail has no archive, trash, or mark-read. **Archive = apply label `deal-ingested`** (fleet-wide convention):

```bash
cortextos bus send-message workspace normal '{"action":"label","thread_id":"<thread_id>","label":"deal-ingested"}'
```

> **gog CLI is NOT installed on this system.** All write ops go through workspace agent.

`label`/`archive` only run when the caller explicitly asks — this skill never labels unprompted.

---

## EXAMPLE SCHEMAS

### Canonical example — deal-listing schema (used by `deal-flow-scan`, PM-confirmed)

These are the **exact field names** the skill must emit per deal. No judgment fields (`multiple`, `asset_class`, `tier`, `notes`) — those are computed downstream by `deal-flow-scan`. The skill returns raw extracted facts only.

```json
{
  "source":      "Deal-source key for the sending alias: quietlight | smbdealhunter | acquireweekly | flippa | manual (derive from the 'from' address)",
  "name":        "Business name / listing headline (subject or first heading)",
  "category":    "Industry / category as stated (e.g. 'SaaS', 'HVAC', 'FBA') — literal, no asset-class bucketing",
  "location":    "City/state. For Quietlight, NOT labeled in body — extract from the SUBJECT via the '<City>-Based' or '<State>-Based' pattern (e.g. 'Seattle-Based' -> 'Seattle, WA'). null for online-only/no-geo listings.",
  "revenue":     "TTM revenue as written; null if absent",
  "sde":         "SDE figure as written. Quietlight labels this 'Earnings' (= SDE) in the Financial Quickview — map 'Earnings' here. null if absent.",
  "ebitda":      "EBITDA figure as written, ONLY if the listing explicitly states EBITDA. Always null for Quietlight (it reports Earnings=SDE, not EBITDA) — expected, not a bug. Never copy the SDE value here.",
  "ask":         "Asking price as written (literal, e.g. '$1.2M'); null if absent",
  "established": "Year established / founded; null if absent",
  "broker":      "Broker or source display name (e.g. 'Quiet Light', 'Flippa')",
  "listing_url": "The listing link from the email body ONLY — never construct or guess; null if not present in the body",
  "body_text":   "The per-deal cleaned listing body text — the prose/specs for THIS listing only, stripped of newsletter chrome (header, footer, unsubscribe, ads, inter-listing dividers, other listings). For a single-deal email this is the whole cleaned body; for a multi-deal email this is just the block for this one listing."
}
```

**Multi-deal emails:** SMBDealHunter (~5 deals/email) and AcquireWeekly (~4 deals/email) pack several listings into one thread. **Split them** — emit one `results` object per deal listing, each with its own `body_text` block, repeating the shared `thread_id` + `subject`. Quietlight and Flippa-featured are typically one deal per relevant block; still split if a thread carries multiple.

### Other example — simple triage schema

```json
{
  "sender":   "From address",
  "intent":   "One of: invoice | receipt | meeting-request | newsletter | other — based on subject + body",
  "amount":   "Any dollar amount mentioned, literal; null if none",
  "due_date": "Any due/deadline date mentioned; null if none"
}
```

---

## HOW A CALLER INVOKES THIS SKILL

The caller (often a Haiku worker) passes the three contract inputs in its prompt, e.g.:

> Invoke the **gmail** skill.
> `query`: `(to:quietlight@monkeyattack.com OR to:flippa@monkeyattack.com)`
> `window`: `newer_than:1d`
> `extraction_schema`: *(the deal-listing schema above)*
> Return the contract JSON.

The skill runs `search` → `extract`, then returns the `{ status, threads_scanned, results }` object. The caller consumes `results` for its own downstream logic (vetting, digesting, DB ingest, etc.). `label`/`archive` are invoked only when the caller asks.

---

## HOUSE RULES

1. **Never fabricate** — values come from `subject`/`body_text` only; URLs especially must be literal or `null`.
2. **Auth failures loud** — `auth_error` returns the error and stops; never disguised as "no results".
3. **No judgment** — this skill does not vet, rank, or decide. It scans, extracts, and (on request) labels/archives. Interpretation is the caller's job.
4. **Don't rebuild auth** — `gmail_search.py` (Vault SA, read) and `gog` (send/label/archive) are already wired.
5. **Cheap by design** — meant for a Haiku sub-agent; keep the work mechanical and avoid context bloat (write the raw JSON to `/tmp`, extract, return rows).

---

_Skill owner: prop-firm-admin (devops mechanics). Backends: `gmail_search.py` (Vault service account, read-only, impersonates meredith@monkeyattack.com) + `gog` CLI (send/label/archive). Consumed by `deal-flow-scan` Stage 1 and any fleet agent needing structured mailbox extraction. Last updated: 2026-06-09._
