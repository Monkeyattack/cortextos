# Quota Tripwire — Fire Drill Report v2
**Date:** 2026-07-10 14:10 CT  
**Author:** devops agent  
**Build:** L1+L2 quota-exhaustion resilience (notes msgs ys8lp/xvtro/gqcf8)  
**Gate:** fable-reviewer — BLOCKED v1 (stale bounds, hardcoded token, no real-threshold drill)  
**This doc:** v2 — addresses all blockers and should-fixes

---

## Changes from v1

| Item | v1 | v2 |
|------|----|----|
| Stale bounds | 2x cron interval (8-12h) | Observed cadence: 2h most agents, 8h workspace |
| BOT_TOKEN | Hardcoded line 18 | Read from devops .env at runtime |
| curl --max-time | Missing | `--max-time 15` added |
| Real-threshold drill | Only always-trip + healthy paths | Real 13/21 trip + 12/21 no-trip |

---

## Drill 1 — Real 60% Threshold Trip (13/21 stale)

**Setup:** Backdated 13 heartbeat.json timestamps to 3h ago (exceeds 2h stale_bound)  
**Agents staled:** chief, analyst, accounts, notes, pm, health, media, reserve, writer, fable-reviewer, lit_agent, pmo, project-manager  
**Expected:** 13/21 = 62% → TRIP (≥60% threshold)  
**Result:** ✅ TRIPPED — latch file created, Telegram queued (real bot call)  
**Script exit:** 0  

---

## Drill 2 — Real 60% Boundary (12/21 stale — must NOT trip)

**Setup:** Restored `chief` to current timestamp → 12/21 stale = 57%  
**Expected:** 57% < 60% → NO TRIP  
**Result:** ✅ NO TRIP — latch not set  
**Script exit:** 0  

---

## Drill 3 — Clean Fleet (post-restore)

**Setup:** All 21 agents restored to current timestamps  
**Result:** ✅ 0/21 stale — no latch, no Telegram  

---

## Stale Bounds Rationale

Per fable-reviewer feedback: bounds derived from OBSERVED heartbeat freshness, not cron config.

Fable-measured ages (Jul 10, during active session):  
chief 0.6h, analyst 0.5h, accounts 0.5h, devops ~0h, notes ~0h, pm 0.3h, health 0.9h, writer 0.3h, media 0.5h, reserve 0.8h, workspace 3.9h (outlier)

| Group | Observed cadence | Stale bound (2x) | Agents |
|-------|-----------------|------------------|--------|
| Fast (20 agents) | ~1h | 2h | All except workspace |
| Slow (workspace) | ~4h | 8h | workspace only |

Detection latency: quota exhaustion detected within ~2h of onset (was 8-12h in v1).

---

## Security: BOT_TOKEN Externalized

Token is now read at runtime from:
`/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/devops/.env`

Script exits with error if token not found. No secrets in source.

---

## Allowlist: Fail-Safe-Halt vs Fallback-Eligible

### FAIL-SAFE-HALT (never fallback — halt only)
| Agent | Reason |
|-------|--------|
| **chief** | Fleet orchestration; wrong decisions cascade |
| **analyst** | Market analysis → trade parameters; wrong = capital risk |
| **accounts** | Live capital state; Apex drawdown tracking |

### FALLBACK-ELIGIBLE (degraded response acceptable)
All other 18 active agents: devops, notes, pm, health, fable-reviewer, lit_agent, ma_studio_*, media, pmo, project-manager, reserve, site_manager, workspace, writer, writer_amazonians, writer_pirate

---

## Full Drill Results Summary

| Drill | Condition | Expected | Actual |
|-------|-----------|----------|--------|
| Force-trip (v1) | Threshold=0% | TRIP | ✅ TRIP (msg_id 2855) |
| Mapping fix | 21/21 resolved | Telegram lands | ✅ msg_id 2856 |
| Real 13/21 stale | 62% > 60% | TRIP | ✅ TRIP (latch set) |
| Real 12/21 stale | 57% < 60% | NO TRIP | ✅ NO TRIP |
| Clean fleet | 0/21 stale | NO TRIP | ✅ NO TRIP |

---

## Timer Installation

**Unit files:** `~/.config/systemd/user/quota-tripwire.{service,timer}`  
**Schedule:** every 30 min, `Persistent=true`  
**First run:** 2026-07-10 13:55:36 CDT — exit 0  
**Enable:** `XDG_RUNTIME_DIR=/run/user/1002 systemctl --user enable --now quota-tripwire.timer`

---

**Status:** Ready for fable gate sign-off v2
