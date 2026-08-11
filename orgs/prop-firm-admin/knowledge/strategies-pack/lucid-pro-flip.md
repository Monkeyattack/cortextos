# LucidProFlip

**Pack version:** 1.0.0 | **Status tier:** LIVE-ACCUMULATING
**Last updated:** 2026-07-30 | **Gate stamp:** pending fable-reviewer

---

## What it is

A market-open flip strategy deployed on Lucid Pro accounts. Similar open-reversal mechanics to MarketOpenFlip but calibrated for Lucid Pro firm rules (DLL $1,200, no consistency rule in funded phase).

## Entry logic

- Direction: Reversal at market open
- Time: 8:30 AM CT (9:30 AM ET)
- Instruments: NQ 09-26 (primary), MES 09-26 (some accounts)

## Instruments and accounts

| Account | Firm | Instrument | Trades | P&L | Status |
|---------|------|------------|--------|-----|--------|
| TDFYG50201122518 | Tradeify/Lucid | NQ 09-26 | 3 | +$60.00 | **BLOWN 2026-08-06 07:05 CT** — all strategies tombstoned (Chris ruling). state=Archived, last_seen 2026-07-30. |
| LTE05059758350007 | Lucid | NQ 09-26 | 2 | -$2,120.00 | **DARK** — no report in 234h as of 2026-08-06 (last_seen 2026-07-27, state=Active in strategy_states). Loaded-state unverifiable until NT8 params snapshot lands (devops task pending). |
| LTE05059758350007 | Lucid | MES 09-26 | 2 | +$940.00 | **DARK** — same account as row above; same stale row covers both instruments. |
| LTE05059758350006 | Lucid | NQ 09-26 | — | — | **DARK** — no report in 383h as of 2026-08-06 (last_seen 2026-07-21, state=Active in strategy_states). Loaded-state unverifiable until NT8 params snapshot lands. |

**Total:** 7 trades, -$1,120.00 all-time. **Reporting accounts: ZERO as of 2026-08-06** — TDFYG blown; LTE accounts dark (no strategy_states report in 234h/383h). Whether LTE accounts are still loaded on their NT8 terminals is unverifiable — no pre-fill read path to deployed NT8 params exists until devops params-snapshot task lands.

## Gate status

**Status tier: LIVE-ACCUMULATING (ZERO REPORTING ACCOUNTS)**

As of 2026-08-06: zero accounts reporting. TDFYG50201122518 blown 07:05 CT (Chris ruling, all strategies tombstoned). LTE05059758350007 and LTE05059758350006 have no strategy_states reports in 234h/383h respectively — dark, loaded-state unknown. Fable-reviewer 12:06Z record "zero live accounts" confirmed correct by live re-derive. Do not call validated.

**7-day reversal flag (2026-07-30):** All-time P&L is only +$40 on some accounts; recent 7-day move shows -$275 reversal. Flagged to chief for awareness — not a threshold breach at current sample size.

## Performance

| Metric | Value | Notes |
|--------|-------|-------|
| All-time trades | 7 | |
| All-time P&L | -$1,120.00 | Small sample |
| Status | LIVE-ACCUMULATING | Not validated |

**Language tier:** LIVE-ACCUMULATING — do not call this "validated." Sample size too small for any performance claims. Report raw numbers and flag trajectory.

## Monitoring notes

- Flag to chief if 7-day P&L continues negative at 15T
- Do not escalate individual losses — 7 trades is too small for pattern detection
- NQ contract risk: full-size, single losing trade can be -$2,000+
