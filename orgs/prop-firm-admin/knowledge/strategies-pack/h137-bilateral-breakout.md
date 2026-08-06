# H137 BilateralBreakout

**Pack version:** 1.0.9 | **Status tier:** VALIDATED
**Last updated:** 2026-08-04 | **Gate stamp:** fable-reviewer 2026-08-04 (see gate-stamps/stamps.jsonl)

---

## What it is

A post-open bilateral breakout strategy on MES (Micro E-mini S&P 500). After the open, it measures a price range; when price breaks cleanly above or below that range, it enters in the breakout direction. One trade per day maximum.

## Signal window vs entry window

These are two separate gates — getting this wrong causes incorrect monitoring.

**Signal window (9:30–10:30 ET):** This is a go/no-go gate only. The strategy uses this window to decide whether it will trade today. It does NOT determine when entry fires.

**Entry signal:** A separate, later signal fires when a clean breakout is detected. Entry has been observed as late as 3:05 PM ET. The strategy can enter any time after the signal window confirms a go day.

## Entry logic

- Direction: Long if price breaks above range high; Short if price breaks below range low
- Instrument: MES 09-26 (rolls quarterly; always use front month)
- Trigger: 5-minute bar close exceeds the range boundary

## Exit logic

Three exit types, in priority order:
1. **TP (take profit):** Unnamed in exit_signal — strategy exits when price reaches the profit target
2. **SL (stop loss):** Unnamed in exit_signal — strategy exits when price hits the stop
3. **EOD exit (H137_Long_EOD / H137_Short_EOD):** Fires on the bar closing after 3:45 PM ET. In practice this is the 3:45–3:50 PM ET bar, exit recorded at ~3:50 PM ET = ~2:50 PM CT. This is DESIGNED behavior — exits before close volatility. IsExitOnSessionCloseStrategy (~4:00 ET) is a backstop only.
4. **MaxHold (H137_Long_TimeExit):** Force-close after 480 minutes. Safety net for runaway holds.

**Reading exit signals:** A bare "Close" in exit_signal = manual flatten by Chris (not a strategy signal). Named signals (H137_Long_EOD, H137_Long_TimeExit) are strategy-generated.

## Instruments and accounts

- **Instrument:** MES only (Micro E-mini S&P). No NQ, no MCL.
- **Contract size:** 1ct = $12.50/tick ($5.00/pt)

**Active accounts (as of 2026-07-30):**

| Account | Firm | Contracts | Notes |
|---------|------|-----------|-------|
| PAAPEX4333770000017 | Apex | 5 | **Pilot account** — pessimistic fill bias (dispatched last). **Sizing doctrine (Chris, 2026-08-04, verbatim): "1 makes no sense. Most of the firms have a minimum winning days, and that often requires $50-150 wins. at 1 contract on MES that is hard to make."** 1ct doctrine RETIRED; 5ct is deliberate policy. Retro-effect: qty=5 flags on Aug-3/Aug-4 dissolve (sizing was policy, not deviation) |
| PAAPEX4333770000002 | Apex | ~10 | Connected fleet |
| APEX4333770000091 | Apex | ~10 | Connected fleet |
| PPNTCASHPPX50024895000003 | Tradeify | ~5 | Connected fleet |
| PPNTETL25024895000005 | Tradeify | TBD | **BREACHED Jul 31** (MarketOpenFlip, -$1,280; DB-verified 2026-08-04) — no longer active |
| MFFUSFFLX450774019 | MFF | ~3 | Connected fleet |
| TAKEPROFITPRO392542906 | Vincere | blind | Blind — no state feed; monitor via trades DB only |
| PAAPEX4333770000010 | Apex | ~10 | Traded from 2026-08-03; added v1.0.8 |
| PPNTCASHF100024895000004 | Tradeify | ~10 | Traded from 2026-08-03; added v1.0.8 |

**Roster caveat (v1.0.8):** live `strategy_states` on 2026-08-04 shows EIGHT active H137 accounts (also PPNTETL25024895000007, not yet tabled). This table lags reality — **derive the account count from `strategy_states` live at claim time, never from this table**; full roster refresh pending analyst.

**Dispatch order:** Pilot (PAAPEX...017) is dispatched LAST to give other accounts pessimistic fill reference.

## Gate status and series (VALIDATED)

**Skip Fridays:** `SKIP_FRIDAYS = True` (backtest variable name, `pd.dayofweek == 4`) — strategy does not trade Friday sessions. Fix committed 374f375 (orbfutures master, Jul 31 16:00 UTC) — also adds VIX<22 gate (backtest: `VIX_MAX = 22.0`) and corrects range window to include 10:30 bar. Prior live code had SkipMondays (wrong) + no VIX gate + range excluded 10:30 bar. **NT8 recompile DONE — Chris confirmed 2026-08-01 8:37 PM CT (chief relay). First corrected-config session: Mon Aug 3 (my prior "Mon Aug 4" was a day-of-week error — Aug 4 is Tuesday; caught by devops).** Prior stamped SkipMondays artifact (stamp 826dc4d3) voided by fable-reviewer 2026-07-31, superseded by 374f375.

**Official series (post-exclusion-ruling 2026-07-29):**
- Valid days: query trades DB — `SELECT COUNT(DISTINCT t.entry_time::date) FROM trades t LEFT JOIN h137_trade_exclusions e ON t.id=e.trade_id WHERE t.strategy_name='H137_BilateralBreakout' AND t.account_name='PAAPEX4333770000017' AND e.trade_id IS NULL` (do not hardcode count — use DB as source of truth; returns 7 as of 2026-08-04 EOD. COUNT(DISTINCT date), not COUNT(*): the series counts DAYS — verified equal to COUNT(*) through 2026-08-04, but they diverge on the first multi-trade day)
- **Exclusion rule:** bare-Close exit_signal = flag for review; strategy-named exit (H137_Long_EOD, H137_Long_TimeExit) = valid. Do not filter on exit_signal to compute the series count.
- **Friday config-conformance ruling (Chris, 2026-07-31):** COUNT ALL. "Win/loss is still just as valid — we are validating profitability, not strict backtest conformance." Friday trades (Jul 24, Jul 31) count toward the series regardless of config divergence active at time of trade.
- **Aug-3 named-day override (Chris, 2026-08-04, verbatim "Yes I scaled"):** Aug 3 COUNTS as day 6. Both flagged deviations resolved as deliberate: qty=5 on the pilot was a Chris scale-up (NOT a recompile DefaultQuantity error — hypothesis independently refuted by devops fleet comparison before the ruling), and the bare-Close exits were a deliberate manual fleet day. Recorded as a named-day override in the Jul-24 class; there is still NO general bare-Close-counts precedent (Jul 27/29 remain excluded per the 07-29 ruling).
- **Aug-4 named-day override (Chris, 2026-08-04, verbatim "counts"):** Aug 4 COUNTS as day 7 — the series' first loss (pilot -$75, Chris flatten 1:31 PM CT; the six fleet legs he closed +$231.25 at 2:02 PM CT). Strategy-dispatched GO day (7-account entry 12:50:05 PM CT, signal H137_Long), all exits manual. Same named-day-override class as Jul-24/Aug-3: each manual-exit day needs its own Chris ruling; no general precedent.
- **Aug-5 named-day override (Chris, 2026-08-05, decision_1785944377 button "COUNT - day 8"):** Aug 5 COUNTS as day 8 — pilot +$387.50 (Short 5ct, entry 9:55:01 CT signal H137_Short, exit 10:18:44 CT). Third consecutive all-manual exit day: brackets cancelled then generic Close filled, staggered closes across all 7 entered accounts, 10:16:01 CT through 12:08:12 CT (6 non-pilot legs +$3,681.25; day total +$4,068.75 incl. pilot). CORRECTED 18:58Z from "6 accounts / +$3,156.25": APEX...091's leg (+$912.50, exit 12:08 CT) had no trades row at first query — write-on-exit lag, the row landed when the position closed 90 min later. Exit-signal mechanism source-verified same day (374f375 emits only named exits; bare Close = external flatten by construction). Series: 8/30, 7W/1L, +$693.75. Same named-day-override class; no general precedent.
- **Language-tier consequence (binding, per gate):** because conformance is not required, the 30-day series outcome validates **live profitability of the as-run config** — it must never be described as "backtest-validated." Pre-374f375 days ran a hybrid config no backtest covers; describe the series result as live-validated profitability only.
- Target: 30 valid days
- Record as of 2026-08-04 EOD: **6W / 1L (7/30)**
- Pilot P&L as of 2026-08-04 EOD: **+$306.25** (DB-authoritative; stale figures retired: $413.75 PM carry-forward, $381.25 pre-Aug-4-ruling)
- Days 9+10 excluded: all-manual exits by Chris (fleet made +$90 / +$1,500 under manual management, tracked separately)

**Payout thresholds (minimum win filters do NOT apply — these are payout minimums):**
- MFF: $150 minimum per payout
- Apex: $50 minimum per payout

**Why 7/30 and not higher:** Strategy launched post-MaxHold fix (480min, was 120min). Clean series started after that recompile.

## Performance

| Metric | Value | Notes |
|--------|-------|-------|
| All-time trades | 25 (as of 2026-07-31) | All MES 09-26 — re-query DB for current |
| All-time P&L | +$3,375 (as of 2026-07-31) | Pilot + connected fleet combined — re-query DB for current |
| Series WR | 85.7% (6W/1L, as of 2026-08-04 EOD) | Small sample — not statistically significant |
| Backtest Sharpe | 2.02 (baseline) | Pre-MaxHold-removal backtest |

**Language tier:** VALIDATED — this strategy has a live real-money series with named exits. Do not call it "backtest-candidate" or reference backtest numbers as performance.

## Monitoring checklist

- Flag any trade immediately to chief (day 4+ = progressing toward payout)
- Pilot flat = series progressing normally; check exit_signal to distinguish TP vs EOD vs manual
- ~~Check exit_time IS NULL to detect open positions~~ **REFUTED 2026-08-04** — an open position has NO trades row at all (see Write Semantics below). Open positions: `query-trades.sh open` (positions table w/ liveness filter) or `query-trades.sh entries` (orders table, what FIRED today).
- TAKEPROFITPRO: monitor via trades DB only; state feed not available from Vincere
- Weekends: strategy monitors normally (signal window fires Mon-Fri only)
## Write Semantics — READ BEFORE QUERYING ANY TABLE (added v1.0.9)

Three write-semantics failures burned the fleet in one week — each by someone who knew the tables well. The semantics live here and in the tool comment blocks (`scripts/query-trades.sh`), not in anyone's memory. **Before writing a query, state to yourself WHEN the row you are reading gets written.**

| Table/surface | Write semantics | Trap it causes | Correct read |
|---|---|---|---|
| `trades` | Row written **ON EXIT** — an open position has NO row | "Today's entries" queries undercount by every open leg; "exit_time IS NULL" open-position checks can NEVER fire (structurally clean-reporting). 2026-08-04: a 7-account dispatch read as pilot-only; 6 live legs invisible | Closed trades only. For what FIRED: `orders`. For what is OPEN: `positions` |
| `positions` | Row per update; **qty=0 close writes can be LOST** — a row can say "open" forever after the position closed | Stale rows read as live exposure (2026-08-04: "4ct NQ open since Jul-30" on the FVG live acct was a closed position with a lost zero-write; also a 4-month-old MCL zombie) | **Liveness test:** a trade EXIT timestamped AFTER the latest positions row = position closed, row stale. Node-absence is ambiguous; this test is decisive. **Known hole:** the test only works on accounts with SOME trades history — a stale row on an account that never produced a trades row passes as "open"; no such case exists as of 2026-08-04, but check trades-history-exists before trusting the test on an unfamiliar account. Lost-write defect: task_1785869632671_bnm0ym |
| `orders` / `executions` | `strategy_name` **MUTATES across lifecycle events** — cancel/update events overwrite it (same order_id observed as H137 at create, MarketOpenVolatility at cancel) | Strategy attribution from any later lifecycle event is unreliable; cross-strategy "ownership" conflicts are writer artifacts | Attribute from the CREATE/submit event only. Corroborate with account trade history (e.g. zero MOV trades in 4d). Writer defect: task_1785869166934_rabesn |
| NT8 API `positions[]` | Carries **NO direction field** (the positions TABLE has it) — same entity, different completeness per surface | Direction-dependent math from the API silently wrong (2026-08-04: SHORT P&L formula circulated because direction was absent from the feed being read) | For direction, read the positions table, not the API. API market_price 0.0 + missing direction: task_1785868418435_kvhjn8 |

All three writer defects share one NT8→Postgres write path; common-root-cause trace is open (lead flagged, not asserted).

- **h137-monitor.sh evening false-zeros (v1.0.8):** the nightly monitor used a `NOW()::date` UTC window with CT labels — after ~7:00 PM CT it reports ZERO trades for the CT day even when trades exist. Nightly reports from 2026-07-2x through 08-03 in that window are unreliable; the trades DB is the only authority for daily counts. Devops fix tracked as task_1785810790946_cf9y16 — until it lands, never trust the monitor after 7 PM CT.
