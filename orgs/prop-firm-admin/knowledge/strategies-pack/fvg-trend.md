**Pack version:** 1.0.1 | **Status tier:** LIVE-ACCUMULATING + SIM-ACCUMULATING
**Last updated:** 2026-08-20 | **Gate stamp:** fable-reviewer T=20 gate registered (C27, 2026-08-20)

> **v1.0.1 corrections (2026-08-20, analyst):**
> - TDFYG50201122518 tier updated: strategy_states stale, live leg effectively inactive — marked blown/stale pending Chris confirmation.
> - Aug-19 SimSim2 sizing incident documented: qty=50 (anomaly) vs qty=1 (all prior trades). True 11-trade baseline = -$147.50. Aug-19 -$3,125 excluded from performance baseline.
> - Backtest WR/expectancy baseline: UNSET — pending Chris confirmation. Required before T=40 gate review.
> - T=20 futility gate registered by fable-reviewer (C27).

---

## What it is

A Fair Value Gap (FVG) trend-following strategy on MES. Identifies imbalance zones (fair value gaps) in price action and enters in the direction of the prevailing trend when price returns to fill the gap. Deployed on both a live real-money account and a SIM account accumulating toward a gate.

## Entry logic

- Identifies FVG (fair value gap) imbalance zones on intraday bars
- Enters on trend continuation after price revisits the gap zone
- Direction: trend-following (not mean-reverting)
- Instrument: MES (09-26 active contract)

## Exit logic

- TP and SL based on gap structure
- EOD exit for any open positions at session end
- Check trades DB exit_signal for specific exits

## Instruments and accounts

| Account | Type | Instrument | Trades (30d) | P&L (30d, adj) | Notes |
|---------|------|------------|--------|-----|-------|
| TDFYG50201122518 | Live (real money) | MES 09-26 | 2 | -$132.50 | **STALE** — strategy_states dark; live leg effectively inactive. Tier downgraded pending Chris confirmation of account/strategy status. |
| SimSim2 | SIM | MES 09-26 | 11 (excl. anomaly) | -$147.50 | Forward-test accumulation. Aug-19 sizing anomaly excluded from baseline (see below). |

**30d adjusted baseline (excl. Aug-19 anomaly):** 13 trades total, -$280.00 combined (-$147.50 SimSim2 + -$132.50 TDFYG).

## Sizing Incident — 2026-08-19 (EXCLUDE FROM PERFORMANCE BASELINE)

SimSim2 entered a Long MES trade on 2026-08-19 at 10:36 CT with **qty=50 contracts** vs the standard qty=1 used in all prior 11 trades. The trade stopped out at -$3,125 (12.5 handles × $1.25/tick × 50 contracts). This is an NT8 configuration error — 50x amplification of a routine stop. 

**Action required:** Chris must reset SimSim2 FvgTrend position size to 1 contract before next trade. Filed as HUMAN task via chief (2026-08-20).

**Gate ruling annotation (fable-reviewer C27):** Aug-19 loss is infrastructure noise. T=20 futility gate criteria (WR ≥ 35%, trades 13-20 net P&L > 0) evaluated against adjusted baseline excluding this trade.

## Gate status

**T=20 FUTILITY GATE (fable-reviewer C27, 2026-08-20):** Active. Criteria pre-registered:
- KILL at T=20 unless trades 13-20 tranche net P&L > 0 AND overall WR ≥ 35% (7+/20)
- Aug-19 sizing anomaly excluded from evaluation
- No promotion before T ≥ 40

**TDFYG50201122518 (live):** Strategy_states dark (stale). Live leg effectively inactive — pending Chris confirmation. Pack tier update to STALE if confirmed inactive.

**SimSim2 (SIM):** T=12 (11 valid + 1 anomaly excluded). Current adjusted T=11 toward T=20 gate. Next review at T=20.

**Live deploy gate:** FvgTrend was deployed live without a formal fable-reviewer gate — noted gap on record.

## Performance

### SimSim2 (SIM) — adjusted baseline (qty=1 only)

| Trade# | Date | Direction | P&L | Exit |
|--------|------|-----------|-----|------|
| 1 | 2026-07-21 | Short | -$30.00 | Stop loss |
| 2 | 2026-07-21 | Long | -$1.25 | StopCancelClose |
| 3 | 2026-07-22 | Long | +$51.25 | Profit target |
| 4 | 2026-07-22 | Long | -$25.00 | Stop loss |
| 5 | 2026-07-23 | Long | -$61.25 | Stop loss |
| 6 | 2026-07-23 | Long | -$70.00 | Stop loss |
| 7 | 2026-07-30 | Long | -$60.00 | — |
| 8 | 2026-08-06 | Short | +$103.75 | Profit target |
| 9 | 2026-08-13 | Long | +$77.50 | Profit target |
| 10 | 2026-08-19 | Long | -$3,125.00 | Stop loss (**ANOMALY: qty=50 — EXCLUDE**) |

**Adjusted 9-trade total (excl. anomaly):** -$15.00 | WR: 3/9 = 33.3%

**Backtest WR/expectancy baseline: UNSET** — required before T=40 gate review. Chris to provide or confirm source.

### TDFYG50201122518 (Live) — 30d

| Trade# | Date | Direction | P&L | Exit |
|--------|------|-----------|-----|------|
| 1 | 2026-07-23 | Long | -$62.50 | Stop loss |
| 2 | 2026-07-23 | Long | -$70.00 | — |

**2-trade total:** -$132.50

**Language tier:** LIVE-ACCUMULATING (TDFYG, if active) / SIM-ACCUMULATING (SimSim2). Not validated. Do not cite performance as evidence of edge — sample is too small.

## Monitoring notes

- **SimSim2 sizing**: Must be 1 MES contract. HUMAN task filed 2026-08-20 for Chris to reset qty before next trade.
- **TDFYG staleness**: Strategy_states dark — confirm with Chris if account/strategy still active.
- **T=20 gate**: Evaluate at T=20 SimSim2 trades (excl. anomaly). Criteria pre-registered by fable-reviewer.
- **Backtest baseline**: UNSET — analyst cannot run T=40 gate review without this. Flag to Chris at T=18.
- **Live deploy gate gap**: Noted — no fable-reviewer stamp on original live deployment.

## Changelog

- **1.0.1 (2026-08-20, analyst):** Sizing incident documented (Aug-19 qty=50 anomaly, -$3,125 excluded from baseline). TDFYG tier downgraded to stale. Backtest baseline flagged UNSET. T=20 futility gate registered (fable-reviewer C27). Trade log expanded with per-trade breakdown.
- **1.0.0 (2026-07-30):** Initial pack.
