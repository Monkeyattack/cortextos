# LucidProFlip

**Pack version:** 1.1.1 | **Status tier:** LIVE-ACCUMULATING
**Last updated:** 2026-08-19 | **Gate stamp:** fable-reviewer (source-anchored correction, see Changelog)

> **v1.1.x correction (2026-08-18):** v1.0.0 called this "open-reversal mechanics." That was
> wrong (same error MOF v1.0 had). Per the live source `LucidProFlip.cs`, it is a **fixed-direction
> hedged pair**, not a reversal. (Re-applied 2026-08-19 after an inadvertent revert to v1.0.0.)

---

## What it is

A market-open **hedged directional pair** on Lucid PRO $50K accounts — the MarketOpenFlip mechanism
calibrated to Lucid PRO rules. NOT a reversal/fade. Two accounts run simultaneously: Account A fixed
**Long**, Account B fixed **Short**. At the 9:30 ET open both enter market orders in their fixed
directions; whichever way NQ moves first hits TP and passes the eval, the other rides to EOD. Runs
the **"let it run" (EOD-only) model** — `StopEnabled = false`, no intraday strategy stop, positions
held to TP or the 16:00 ET EOD flatten.

## Entry logic

- **Direction: fixed per account** (A = Long, B = Short), set before the open — NOT a function of the
  opening move. (v1.0.0's "reversal at market open" was incorrect.)
- Time: 9:30 AM ET (8:30 AM CT) market open, market order.
- Instrument: **4 NQ E-mini** ($80/pt) — Lucid PRO $50K max is 4 mini OR 40 micro (economically
  identical at $80/pt). MES on some legacy accounts.
- **TP: 155 ticks** (38.75pt = $3,100 gross, ~$3,080 net) — sized for a **1-day eval pass** of the
  $3,000 target (Lucid PRO allows a 1-day pass, no eval consistency). *Changed from 125t on
  2026-08-18, Chris GO — see market-open-flip pack and LucidProFlip.cs.*

## Exit logic (EOD-only "let it run")

- TP hit → ~$3,080 net locked in, clears the $3,000 eval in one session.
- No intraday stop (`StopEnabled = false`). Loser rides to the 16:00 ET EOD flatten.
- Lucid PRO drawdown = $2,000 **EOD-measured** trailing (intraday dips that recover do not trigger).
- **No DLL below the initial trail** (verified vs live Lucid PRO Funded rules 2026-08-18; the old
  "$1,200 DLL" figure was stale). LucidScale DLL (60% of peak EOD balance) applies only above the
  initial trail. So the ride-to-EOD genuinely works on a fresh account.

## Instruments and accounts

| Account | Firm | Instrument | Trades | P&L |
|---------|------|------------|--------|-----|
| TDFYG50201122518 | Tradeify/Lucid | NQ 09-26 | 3 | +$60.00 |
| LTE05059758350007 | Lucid | NQ 09-26 | 2 | -$2,120.00 |
| LTE05059758350007 | Lucid | MES 09-26 | 2 | +$940.00 |

**Total:** 7 trades, -$1,120.00 all-time

## Gate status

**Status tier: LIVE-ACCUMULATING** — live on real accounts but sample insufficient for validated status. 7 trades across 30 days — too early to confirm edge. Monitor trajectory; do not call validated.

**Language tier:** LIVE-ACCUMULATING — do not call this "validated." Sample too small for any performance claims. Report raw numbers and flag trajectory.

## Performance

| Metric | Value | Notes |
|--------|-------|-------|
| All-time trades | 7 | |
| All-time P&L | -$1,120.00 | Small sample |
| Status | LIVE-ACCUMULATING | Not validated |

## Monitoring notes

- Flag to chief if 7-day P&L continues negative at 15T.
- Do not escalate individual losses — 7 trades is too small for pattern detection.
- Contract risk: 4 NQ E-mini = $80/pt; the blown leg can reach the -$2,000 EOD trail (by design, paired structure).

## Changelog

- **1.1.1 (2026-08-19, fable-reviewer):** Re-applied the v1.1.0 source-verified corrections after analyst inadvertently reverted the pack to v1.0.0. Content = v1.1.0 (chief cleared; fable-reviewer holds canonical).
- **1.1.0 (2026-08-18, fable-reviewer):** Source-anchored correction vs `LucidProFlip.cs` — mechanism (open-reversal → fixed-direction hedged pair), documented the EOD-only "let it run" model, updated config (TP 125t→155t for 1-day pass, 4 NQ, StopEnabled=false), corrected the stale $1,200-DLL note.
- **1.0.0 (2026-07-30):** Initial pack.
