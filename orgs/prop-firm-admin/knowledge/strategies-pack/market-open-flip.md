# MarketOpenFlip (MOF / FLIP)

**Pack version:** 1.1.3 | **Status tier:** VALIDATED
**Last updated:** 2026-08-19 | **Gate stamp:** fable-reviewer (source-anchored correction, see Changelog)

> **v1.1.x correction (2026-08-18):** the v1.0.0 pack described MOF as a single-account
> "reversal/fade" on NQ full-size. That was wrong on the mechanism and the instrument. Corrected
> below against the authoritative live source `MarketOpenFlip_live.cs`. The "flip" is a **fixed-direction
> hedged pair**, not a fade; the production instrument is **MNQ micro**, and NQ full-size is explicitly
> banned as 10x oversized. (Re-applied 2026-08-19 after an inadvertent revert to v1.0.0 — see Changelog.)

---

## What it is

A market-open **hedged directional pair** ("flip") on Nasdaq-100 micro futures (MNQ). It is NOT
a reversal/fade — there is no exhaustion or opposite-side logic. Two accounts at **different prop
firms** run the strategy simultaneously: one is configured **Long**, the other **Short**. At the
9:30 AM ET open (8:30 AM CT), both enter market orders in their fixed directions. Whichever way
NQ moves first, that account hits TP and passes its eval; the opposite account is blown by the
firm's drawdown. Expected outcome: **one eval passes per flip attempt** — the cost of the blown
account is the price of passing the other. Port of the MT5 market-open-flip strategy.

## Entry logic

- **Direction: fixed per account, set before the open** — Account A = Long, Account B = Short.
  Direction is a config parameter, NOT a function of the opening move. (v1.0.0's "opposite to the
  opening move" was incorrect.)
- **Two simultaneous entries** across two cross-firm accounts — not one trade/day.
- Instrument: **MNQ** (micro NQ), 1-minute chart, one strategy instance per account.
- Time: Market open (8:30 AM CT / 9:30 AM ET), market order.
- Sizing (production, Apex 4.0): **Economic config = 30 MNQ contracts** (single-day fallback = 46).

## Exit logic

- **Take Profit:** 116 ticks (= 29 MNQ points), Economic config → $1,740, ~89% pass rate.
  Tier note from source: 25k/50k may use TP 132t; 100k/150k use TP 156t.
- **Stop Loss:** 133 ticks — sized to the losing side's Apex trailing-DD budget (the loser is
  auto-liquidated at the drawdown floor, not by a discretionary stop).
- **Max hold:** 90 minutes in the live `.cs` default (force-close if neither TP nor SL hit).
  *Note: this MaxHold was flagged as arbitrary and dropped for the 2026-08 hold-to-close research
  experiments; the LIVE strategy still carries it — do not conflate the research config with live.*
- **Session close:** `IsExitOnSessionCloseStrategy = true` (exit 30s before session close).
- Large individual wins (passing leg) and losses (blown leg) are by design.

## Instruments and accounts

- **Instrument:** **MNQ (Micro E-mini Nasdaq-100), $0.50/tick, $2/point.** Production config per the live source.
- **NQ full-size is explicitly BANNED** in the source: "NEVER use NQ full ($5/tick — 10x oversized)."
- **Hedge rule:** Long on firm A, Short on firm B — **cross-firm only. NEVER same firm,
  opposite direction.** (Consistent with the org cross-broker hedging rule.)
- **Historical instruments:** M2K (Micro Russell), MCL (Micro Crude) in early runs.

### Instrument note — DB labels NQ-full, but the large-qty rows are suspect data (2026-08-18)

The live trades DB labels most MOF fills as **NQ 09-26 full-size** (not the `.cs`-mandated MNQ micro),
a real label/config question worth confirming. **But an earlier flag overstated the magnitude:** two
rows showing ~30–35 contracts (which drove a "10x oversize, +$22K" alarm) are almost certainly **data
artifacts, not real fills** — lone singletons on an Apex account whose contract cap is 6 minis, and a
35-lot NQ order cannot execute there (confirmed with Chris 2026-08-18). The genuine MOF NQ rows are
**2–6 contracts** — near or within caps. So:

- Do **not** cite the ~35-contract rows or the inflated P&L as evidence of a live oversized position.
- The legitimate open question is narrower: are the small NQ-full fills intentional, or should the
  strategy be on MNQ micro per the `.cs`? At small size NQ-full still carries ~10x the per-point risk
  of MNQ (a 3-lot NQ losing 48pt ≈ −$2,850, alone exceeding a $2,000 DD), so the instrument choice
  still matters — just not at the artifact magnitude.
- Lesson: dashboard trade rows can carry non-executable/aggregated/mislabeled values; verify qty
  against the account's contract cap before treating a row as a real fill.

**Active accounts (representative, as of 2026-07-29):**
Multiple eval and funded accounts across Apex, MFF, Tradeify. Rotates as accounts pass/fail evals. Not pinned to specific accounts — check strategy_states for current loaded accounts.

## Gate status (VALIDATED)

- **All-time trades:** 49 | **All-time P&L:** +$15,276.80 | **Timeframe:** 2026-04-20 → 2026-07-29 | **Recent:** 10 trades/30d

**Language tier:** VALIDATED — live real-money series over 3+ months. Reference live P&L only. *Caveat: the P&L may reflect the NQ-full oversized config (see instrument note), pending analyst reconciliation — the mechanism description is corrected; the live numbers are unaudited by this edit.*

## Performance

| Metric | Value |
|--------|-------|
| All-time trades | 49 |
| All-time P&L | +$15,276.80 |
| Avg P&L/trade | +$311.77 |
| Trades last 30d | 10 |

*Numbers carried from v1.0.0 (analyst-owned live data). Backtest reference from source: 97.9% win rate over 146 trading days (Sep 2025–Mar 2026, Polygon). Source integrity note: the original "100% win rate" claim came from a 25-day yfinance sample that missed every loser — do not cite it.*

## Monitoring notes

- High-volatility strategy — individual swings are large by design.
- **Each flip is a PAIR:** one account is expected to pass (TP) and one to blow (DD floor). A "loss" on the blown leg is the designed cost of passing the other — do not read a single leg in isolation.
- MNQ micro is the intended instrument; NQ full = 10x notional. A single NQ-full losing leg can be −$2,000+ and indicates a misconfiguration (see instrument note).
- Do NOT flag individual large losses as anomalies — check the all-time trend and the paired context.
- Monitor for: strategy going dark >3 days during active trading periods.

## When is the no-SL "let it run" hold rational (2026-08-18, fable-reviewer + analyst)

The ~66% loser-recovery finding is a price-path property; realizing it requires the account to
**survive the intraday adverse excursion**. Two conditions must BOTH hold:

1. **Cushion > MAE dollar risk.** MOF max-adverse-excursion is a median ~162pt / max ~554pt (NQ
   points) = ~$3,240 median / ~$11,080 max **per contract** at NQ full ($20/pt). On a $50K account
   with ~$2,000 trailing DD, NQ sizing blows before recovery — the no-SL hold is negative-EV there.
   Size so the cushion survives the MAE (MNQ micro, or a larger account).
2. **Firm judges drawdown at EOD close, not intraday.** On intraday-trailing firms (Apex) the MAE
   liquidates the account before recovery can occur — the ride is impossible regardless of size. On
   EOD-measured firms (Lucid PRO / Phidias Premium — no intraday DLL below the initial trail) the
   loser rides the excursion unmolested and is judged at the close, so recovery is realizable.

So the fix for a blowing loser is **size AND firm substrate**, not size alone. This is why the flip
re-homing (2026-08-18) targets EOD-DD firms.

## Changelog

- **1.1.3 (2026-08-19, fable-reviewer):** Re-applied the v1.1.x source-verified corrections after analyst inadvertently reverted the pack to v1.0.0 (rewrote from its own stale knowledge ~00:30 UTC). Content = v1.1.2 (chief cleared; fable-reviewer holds canonical). Standing guard: check fable-reviewer KB before rewriting strategies-pack.
- **1.1.2 (2026-08-18, fable-reviewer + analyst):** Added "when is the no-SL hold rational" — recovery realizable only when cushion > MAE dollar risk AND the firm judges DD at EOD close.
- **1.1.1 (2026-08-18, fable-reviewer):** Downgraded the instrument flag — the ~35/30-contract NQ rows are data artifacts, not live fills. Narrowed to the real question (NQ-full vs MNQ at 2-6 ct).
- **1.1.0 (2026-08-18, fable-reviewer):** Source-anchored correction vs `MarketOpenFlip_live.cs` — mechanism (reversal/fade → fixed-direction hedged pair), instrument (NQ full → MNQ micro, NQ banned), TP/SL/MaxHold/session-close specifics, paired structure.
- **1.0.0 (2026-07-30):** Initial pack.
