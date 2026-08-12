# MarketOpenVolatility (MOV)

**Pack version:** 1.0.0 | **Status tier:** LIVE-ACCUMULATING (partially active)
**Last updated:** 2026-07-30 | **Gate stamp:** pending fable-reviewer

---

## What it is

A market-open volatility strategy that capitalizes on directional volatility at the open. Multiple variants and instruments have run over time; current focus is on MES (Micro E-mini S&P). The MES arm is under active rebuild.

## Entry logic

- Enters at or near market open (8:30 AM CT / 9:30 AM ET)
- Directional: takes a position based on early volatility signal
- Instruments: MES (current), previously MCL, MNQ

## Instrument history

| Instrument | Period | Notes |
|------------|--------|-------|
| MCL (Micro Crude) | 2026-04 to 2026-07-03 | Retired; last trade Jul 3 |
| MNQ (Micro Nasdaq) | 2026-06 only | Small run |
| MES (Micro S&P) | 2026-05 to 2026-07-28 | **Current focus** |

**Contract expiry watch:** MCL rolls monthly. MES/MNQ roll quarterly. When an instrument goes dark >2 weeks, check contract expiry before assuming strategy failure.

## Current status

**MES arm rebuild:** Chris GO on rebuild 2026-07-27. Rebuild scope under discussion; MES on SimSim2 as of 2026-07-28 (2T, -$51.25). Strategy_states shows Active on SimSim2.

**OVX gate:** MOV (MCL/MNQ variants) is gated behind OVX. When OVX >50 = HARD-CAUTION, MCL/MNQ variants are paused. Current OVX: 67.6 (HARD-CAUTION) — MCL/MNQ variants should not be trading.

## All-time performance

| Metric | Value | Notes |
|--------|-------|-------|
| All-time trades | 148 | All instruments combined |
| All-time P&L | -$3,171.75 | Mixed period including CL contamination |

**CL contamination note (2026-05-30):** Some accounts ran full CL (crude oil, 10x contract size) instead of MCL in early periods. Bad CL sessions dragged all-time P&L down significantly. Intended instrument was always MCL. All-time P&L should not be cited without this caveat.

**MCL contract expiry pattern:** MCL 05-26 expired ~May 16. Strategy appeared dormant (0 trades Apr 15 to May 30) even though orb-status was ACTIVE. Always check contract expiry when an instrument goes dark >2 weeks.

## Accounts

Multiple accounts across Apex, MFF, Tradeify have run MOV variants at different times. Check strategy_states for current Active accounts. HolyGrail fleet has 1 MOV slot (per Chris 2026-07-24).

**Orb-status gate:** orb-status controls MOV variants only. Excalibur is NOT controlled by orb-status — separate mechanism.

## MNQ VIX Regime — fable-reviewer Ruling 2026-08-11

**Ruling: GO — tighten MNQ VIX pause threshold from ≥20 to ≥18.**

**Evidence (IS-derived — backtest-candidate language tier, not validated):**

H201 MNQ ORB VIX-tier segmentation (IS 2025-09-01 → 2026-06-20, T=150 total):

| VIX Tier | T | WR | Sharpe | Total P&L | Live Status |
|---|---|---|---|---|---|
| <15 (LongOnly engine) | 2 | 50.0% | -0.18 | -$35 | Active |
| 15–18 | 83 | 49.4% | 1.18 | +$1,508 | Active — **sweet spot** |
| 18–20 (decision bucket) | 29 | 34.5% | -0.72 | -$544 | Active → **proposed excluded** |
| 20–22 (already excluded) | 13 | 46.2% | 0.50 | +$280 | Already paused (VIX≥20 rule) |
| 22–25 (already excluded) | 14 | 14.3% | -3.05 | -$1,150 | Already paused |
| ≥25 (ShortOnly engine) | 9 | 66.7% | 1.32 | +$536 | Already paused |

**Impact of tightening (IS-derived):**
- Current live universe (VIX<20): T=114, WR=45.6%, Sharpe=0.62
- Proposed universe (VIX<18): T=85, WR=49.4%, Sharpe=1.14

Decision bucket VIX 18-20 is the sole cost: T=29, Sharpe=-0.72. Removing it lifts Sharpe 0.62→1.14.

**Note:** MNQ ORB VIX sensitivity is the **inverse** of VWAP strategies (H178, H184 gain edge at elevated VIX). Do not apply this ruling to other instruments.

**30-session review:** Starting from devops deploy date (TBD — pending Chris morning brief visibility). After 30 live sessions under VIX<18 filter, re-derive WR/Sharpe from trade DB to confirm IS finding holds in live data.

**Deploy action (pending devops):** Update MNQ VixMax in NT8 NinjaScript from 20 → 18, and update VIX pause threshold in `backtest/forward_test.py` to match.

**Execution chain (post Chris morning brief approval):**
1. Chris approves in morning brief
2. devops updates VixMax=18 in NT8 NinjaScript for MNQ ORB
3. Chris reads parameter back from NT8 terminal = immediate config confirmation
4. Analyst queries `mov_sessions.vix_regime` on first VIX 18-20 session post-deploy (see query below) — expects regime flip from `Both` to pause/skip. If regime does NOT flip on a VIX 18-20 session, that is a failed deploy signal.

**Step 4 verification query (run after first VIX 18-20 session post-deploy):**
```sql
SELECT session_date, account_name, session_vix, vix_regime, effective_direction
FROM mov_sessions
WHERE instrument = 'MNQ'
  AND session_vix >= 18.0
  AND session_vix < 20.0
  AND session_date >= '<DEPLOY_DATE>'
ORDER BY session_date DESC
LIMIT 10;
```
Replace `<DEPLOY_DATE>` with the actual devops deploy date. Expected result: `vix_regime` column shows a pause/skip code (NOT `low` or `normal` + `Both`). If any row shows `effective_direction = 'Both'` at VIX 18-20, the deploy failed — escalate to devops immediately.

## Language tier

LIVE-ACCUMULATING (partially active). MCL/MNQ variants effectively paused (OVX HARD-CAUTION). MES arm rebuilding. Do not call validated — all-time P&L is negative and instrument contamination complicates the history.

MNQ VIX regime ruling (2026-08-11): IS-derived (backtest-candidate). Not validated until 30-session live review confirms.

## Monitoring notes

- MES arm: monitor SimSim2 fills; no alerts on small losses during rebuild
- MCL/MNQ: expect no trades while OVX >50 (HARD-CAUTION)
- OVX <40 = resume-signal; 40-50 = elevated-caution; >50 = hard-caution
- HolyGrail slot: 1 MOV instance confirmed in fleet (zombie rows from earlier were cleaned up)
