---
name: backtest
description: Use when user wants to backtest the MOV strategy, compare instruments, analyze performance, or tune risk parameters. Triggers on "backtest", "test MCL", "run comparison", "how would X perform", or parameter tuning requests.
---

# MOV Backtest Workflow

## Overview

Smart wrapper for the orbfutures MOV backtesting system. Translates natural language requests into correct CLI invocations, runs the backtest, and provides actionable analysis of results.

## When to Use

- User says "backtest", "test", "run", "compare", or "how would X perform"
- User asks about strategy performance over a date range
- User wants to compare risk levels or instruments
- User wants to tune parameters and see impact

## Quick Reference

### Instruments
| Code | Polygon Proxy | ORB Window (ET) | Smart Exits |
|------|--------------|-----------------|-------------|
| MCL | USO | 9:00-9:05 | OFF (cost -$575) |
| MES | SPY | 9:30-9:35 | OFF |
| MNQ | QQQ | 9:30-9:35 | ON (RSI+EMA validated) |

### Risk Levels
| Level | TP% | SL% | R:R | Use Case |
|-------|-----|-----|-----|----------|
| conservative | 0.33 | 0.17 | 2:1 | Reference only |
| **standard** | **0.50** | **0.25** | **2:1** | **Funded accounts** |
| aggressive | 0.75 | 0.33 | ~2.3:1 | Reference only |
| eval_mnq | 2.00 | 1.00 | 2:1 | MNQ eval accounts (4x risk) |

### CLI Flags
```
python -m backtest.run \
  --instrument {MES|MNQ|MCL|ALL} \
  --start YYYY-MM-DD \
  --end YYYY-MM-DD \
  --risk {standard|conservative|aggressive|eval_mnq} \
  --account 50000 \
  --rate-limit 5 \
  -v
```

## Workflow

### 1. Parse Intent

Map natural language to CLI parameters:
- `"backtest MCL last 3 months"` → `--instrument MCL --start (today-90d) --end (today)`
- `"compare all instruments funded"` → `--instrument ALL --risk standard`
- `"test MNQ eval mode"` → `--instrument MNQ --risk eval_mnq`
- `"how does MCL do in Q4"` → `--instrument MCL --start 2025-10-01 --end 2025-12-31`

**Defaults when not specified:**
- Instrument: MCL (user's active instrument)
- Risk: standard
- Account: 50000
- Date range: last 6 months

### 2. Pre-Flight Checks

Before running:
1. Verify working directory is `orbfutures` repo
2. Check if Polygon API key is available (Vault or env var)
3. Check for cached data in `data/` directory (avoids unnecessary API calls)
4. Warn if date range is very large (>6 months = many API calls with rate limiting)

```bash
# Check for cached data
ls data/*.parquet 2>/dev/null

# Check API key availability
python3 -c "from backtest.data_fetcher import _API_KEY; print('Key found' if _API_KEY else 'No key')"
```

### 3. Run Backtest

Execute from the orbfutures project root:
```bash
cd /home/claude-dev/repos/orbfutures
python -m backtest.run --instrument MCL --start 2025-09-01 --end 2026-03-15 --risk standard --account 50000 -v
```

**Important:** The engine always runs BOTH Variant A (static exits) and Variant B (smart exits) side-by-side. Smart exits only activate for instruments where `use_smart_exits=True` (currently only MNQ).

### 4. Analyze Results

After the backtest completes, focus analysis on these key metrics:

**Health indicators (flag if concerning):**
- Win rate < 45% → strategy may not suit current regime
- Max drawdown > 5% of account → risk too high
- Consecutive losses > 5 → check for regime shift
- EOD exit % > 30% → TP/SL too wide, not closing intraday
- Sharpe < 1.0 → risk-adjusted returns weak

**Apex compliance checks:**
- Stop loss must not exceed 5x profit target in ticks
- 30% MAE rule: open loss cannot exceed 30% of SOD balance
- Must be flat by 4:59 PM ET (strategy exits 4:55 PM)
- One trade per day only

**Comparison guidance:**
- If Variant B (smart exits) outperforms A for an instrument → consider enabling smart exits
- If Variant B underperforms → keep smart exits OFF (like MCL where it cost -$575)

### 5. Suggest Next Steps

Based on results, suggest:
- Parameter adjustments (risk level changes)
- Instrument-specific tuning
- Date range refinements to isolate regime changes
- Whether to update the NinjaTrader XML templates

## Common Patterns

### Multi-Instrument Comparison
```bash
python -m backtest.run --instrument ALL --start 2025-09-01 --end 2026-03-15 --risk standard -v
```

### Eval vs Funded Comparison
Run MNQ twice with different risk levels:
```bash
python -m backtest.run --instrument MNQ --risk eval_mnq --start 2025-09-01 --end 2026-03-15 -v
python -m backtest.run --instrument MNQ --risk standard --start 2025-09-01 --end 2026-03-15 -v
```

### Isolate a Bad Period
If user reports losses in a specific week:
```bash
python -m backtest.run --instrument MCL --start 2025-12-15 --end 2026-01-10 --risk standard -v
```
Note: Calendar blackout (Dec 20 - Jan 5) will skip those days automatically.

## Data Pipeline

1. **Polygon API** → fetches 1-min bars for ETF proxies (SPY/QQQ/USO)
2. **VIX data** → tries local FRED CSV (`data/VIXCLS.csv`) first, then Polygon API
3. **Caching** → parquet files in `data/` directory, reused on subsequent runs
4. **Trade logs** → exported as CSV to `data/trades_{INST}_{VARIANT}_{TIMESTAMP}.csv`

## Common Mistakes

- Running from wrong directory (must be orbfutures root)
- Forgetting that MCL uses 9:00 ET window, not 9:30
- Comparing eval_mnq risk against standard without noting the 4x risk difference
- Ignoring calendar blackout period in Dec-Jan results
- Using `--rate-limit` too high on free Polygon tier (5/min is safe)
