# wake-on-alert manifest

Timer → origin-cron mapping, so nothing here is untracked and every entry can be rolled back by
someone who did not build it.

**Why this file exists:** these scripts replace daemon crons. A daemon cron is visible in
`cortextos bus list-crons`; a user-crontab line is not. Without this mapping, a future operator sees
a disabled cron with no idea what took over, or a crontab line with no idea what it replaced.

## Active

| Timer | Origin cron | Agent | Cadence | Status |
|---|---|---|---|---|
| user crontab `9 * * * *` → `reserve-heartbeat-stamp.sh` | `heartbeat-stamp` | reserve | 1h | **MIGRATED** 2026-08-12 20:09Z. 3/3 cycles, rollback drilled, read-back added 2026-08-13 |
| user crontab `13 * * * *` → `pmo-heartbeat-stamp.sh` | `heartbeat-stamp` | pmo | 1h | **MIGRATED** 2026-08-13 01:35Z. 3/3 cycles, dual-source negative checks. Read the caveat below |
| user crontab `19 * * * *` → `workspace-heartbeat-stamp.sh` | `heartbeat-stamp` | workspace | 1h | **MIGRATED** 2026-08-13 04:27Z. 3/3 cycles, dual-source negatives (corrected assertion). Read the caveat below |

## What "MIGRATED" in the table above does and does NOT mean

**Standing caveat. It applies to every row, and it does not shrink as more crons pass.**

Three cycles proves **agent-independence and the mechanism** — the script runs unattended on its own
schedule, the origin cron stays dead, and the effect lands. That is the whole of it.

Three cycles does **not** test:

- an **unattended week** — every cycle so far was watched, in real time, by the person who built it
- a **daemon restart** or a **box reboot**
- the **crontab surviving** a home-directory change, a host rebuild, or a user migration — and a
  crontab line, unlike a daemon cron, appears in no cortextos surface at all
- behaviour under the **load spikes** this box actually experiences (a 3s job took 96s once)

The failure mode I would expect first is none of the ones tested: **the crontab line quietly ceasing
to exist**, with `list-crons` and heartbeat freshness both still reporting healthy (see `PATTERN.md`
— they each do this for a different reason).

Read `MIGRATED` as "proven on the axis it was tested on", not as "safe". Same standing as the
**BY CONSTRUCTION ONLY** note on criterion 4: the honest verdict is conditional, and a future reader
must not find a bare pass.

### pmo/heartbeat-stamp

- **Origin cron:** `~/.cortextos/default/.cortextOS/state/agents/pmo/crons.json`, name
  `heartbeat-stamp`, now `enabled: false` with a `disabled_reason` carrying its own rollback command.
  **Not deleted** — `fire_count: 1289` and history preserved.
- **Replacement:** `pmo-heartbeat-stamp.sh`, user crontab, hourly at `:13` — offset from reserve's
  `:09` and writer's `:11` to avoid stacking on an 8-core box.
- **Authorised by:** chief, 2026-08-13, message `1786584871565-chief-yk7h7`.
- **Worksheet:** `worksheet-pmo-heartbeat-stamp.md`. Criterion 4 is satisfied **by construction only**
  — without the read-back this cron is NOT Class A.
- **Migration order:** default double-fire-safe (disable → gate → install → gate). pmo *is*
  idempotent and could have used the gap-minimising exception; the default was chosen deliberately so
  the second migration exercises the general rule rather than the carve-out.
- **Backups:** session scratchpad `crontab.pre-pmo`, `pmo-crons.pre.json`.
- **Verified at migration:** forced-failure PASS (exit 1, alert delivered as pmo), success-path PASS
  (heartbeat advanced `01:33:50Z` → `01:36:03Z`).
- **Verified 3/3:** negatives at the `:11` slot held across all three cycles — `fire_count` frozen at
  `1289`, dual-source. Cycles 02:13:03Z, 03:13:02Z, 04:13:03Z. Gated by fable-reviewer.

### workspace/heartbeat-stamp

- **Origin cron:** `~/.cortextos/default/.cortextOS/state/agents/workspace/crons.json`, name
  `heartbeat-stamp`, now `enabled: false` with a `disabled_reason` carrying its own rollback command
  and the `fire_count` baseline to verify against. **Not deleted** — `fire_count: 1206` and history
  preserved.
- **Replacement:** `workspace-heartbeat-stamp.sh`, user crontab, hourly at `:19` — offset from
  reserve `:09` and pmo `:13`, and clear of the daemon offsets `:07/:11/:17/:23/:37/:53`. The box is
  8 cores; stacking migrated crons on one minute manufactures the contention that produced the 96s
  outlier.
- **Authorised by:** chief fleet-rollout GO, 2026-08-13, message `1786584871565-chief-yk7h7`
  (gate PASS from fable-reviewer 04:22Z preceding it).
- **Worksheet:** `worksheet-workspace-heartbeat-stamp.md`. Criterion 4 satisfied **by construction
  only** — without the read-back this cron is NOT Class A. Carries a **known open defect** knowingly:
  the read-back's same-second false-alarm (fails loud, not open); fix direction is
  inconclusive-and-retry-once, filed for post-freeze.
- **Migration order:** default double-fire-safe (disable → gate → install → gate). workspace *is*
  idempotent and could have used the gap-minimising carve-out; the default was chosen so the third
  migration exercises the general rule.
- **Backups:** session scratchpad `crontab.pre-ws`, `ws-crons.pre.json`.
- **Verified at migration:** forced-failure PASS (exit 1, alert delivered as workspace,
  `1786595217527-workspace-kay1y`, isolation **gated** not merely printed); success-path PASS
  (heartbeat `04:27:35Z` → `04:27:43Z`, read-back confirmed the advance).
- **Verified 3/3:** cycles 05:19:02Z, 06:19:02Z, 07:19:02Z. Negatives dual-source under the
  **corrected** standard — `crons.json` `fire_count` frozen at 1206 **and** the daemon
  `cron-execution.log` last entry `04:11:38.810Z` predating the `04:27:23Z` migration.
  **Cycle 1's source B was invalid as written** (count comparison against a rotating log); it was
  re-derived by hand and holds, but cycles 2 and 3 are the first valid as written. See the worksheet.

### reserve/heartbeat-stamp

- **Origin cron:** `~/.cortextos/default/.cortextOS/state/agents/reserve/crons.json`, name
  `heartbeat-stamp`, now `enabled: false` with a `disabled_reason` pointing here. **Not deleted** —
  `fire_count: 977` and history preserved.
- **Replacement:** `scripts/wake-on-alert/reserve-heartbeat-stamp.sh`, user crontab, hourly at `:09`
  (offset from the fleet's `:00` cluster).
- **Authorised by:** chief, 2026-08-12, message `1786565008957-chief-ens9w`.
- **Backup of pre-change crons.json:** session scratchpad `reserve-crons.json.bak`.

**ROLLBACK — THREE steps, STRICT order.** See `PATTERN.md` for the full procedure and rationale.

The earlier version of this section said "two steps, either order". **That was wrong and it broke
during the 2026-08-13 drill.** `crontab <path>` failed on a long path and silently did nothing while
the re-enable succeeded, putting reserve into the double-fire state this pilot exists to eliminate
for 19 seconds. Order and verification are load-bearing.

```bash
# 1. Remove the crontab line — via STDIN. `crontab <path>` is length-sensitive here and FAILS.
crontab -l | /usr/bin/grep -v 'LEVER1-PILOT' | crontab -

# 2. GATE — must print 0. If it does not, ABORT. Do NOT run step 3.
crontab -l | /usr/bin/grep -c 'LEVER1-PILOT'

# 3. Only after step 2 prints 0.
cortextos bus update-cron reserve heartbeat-stamp --enabled true
```

**Re-enabling does not restore coverage immediately** — the catch-up gate suppresses missed slots, so
expect a gap of up to one full interval (1h here). Verify `fire_count` actually advances before
treating reserve as covered.

### Do NOT hand-edit `crons.json` to enable or disable a cron

**Editing the file does nothing until the daemon is told.** `enabled` is read only inside
`loadCrons()` (`src/daemon/cron-scheduler.ts:370`), which runs at scheduler start and on an explicit
`reload()`. `reload()` is reachable only over IPC — `reload-crons`, `add-cron`, `update-cron`,
`remove-cron` (`src/daemon/ipc-server.ts:749/819/834/848`). **There is no file watcher.** A
hand-edited `enabled: false` leaves the in-memory schedule untouched and the cron keeps firing.

This is not hypothetical: it is exactly what happened when this pilot went live on 2026-08-12. The
disable was written by hand at 20:07Z; the daemon fired the "disabled" cron at 21:06:36.250Z
(`fire_count` 977 → 978, `last_fire_attempted_at` set — the `dispatchFire` signature). For ~1h the
pilot was **double-running**: the daemon injecting an LLM turn at `:06` *and* the crontab script at
`:09`. The saving the pilot exists to measure was zero during that window.

`cortextos bus update-cron ... --enabled false` writes the field **and** calls `signalCronReload()`
(`src/cli/bus.ts:2289`). Use it. The same trap applies to any other agent's crons.

**How to know the disable actually took:** not from `list-crons` and not from the file — from the
absence of a fire. `last_fired_at` must be unchanged one full interval later.

## Verification performed before go-live

- **Success path:** ran the real script directly — exit 0 in 7s, reserve's `heartbeat.json` updated
  to `auto-stamp — active session`.
- **Forced-failure path (gate criterion, non-negotiable):** ran a **copy** with the command broken to
  `cortextos-DOES-NOT-EXIST`. Result: exit 1, `FAIL` line in
  `logs/reserve/wake-on-alert.log`, and a `high`-priority alert delivered to chief's inbox as
  `1-1786565203907-from-reserve-v6fkx.json`. The real script was never modified — the test ran on a
  scratchpad copy, so there was nothing to "restore" afterwards.
- **Not yet observed at go-live:** N=3 unattended cycles. Until those pass, this is a pilot, not a
  pattern.

**The N=3 count was restarted at 2026-08-12 21:10Z.** Cycles run before that point are not
admissible: the origin cron was still firing (see the rollback section above), so reserve's
heartbeat had two writers and a stamp could not be attributed to this script. The pilot's claim is
"the heartbeat is stamped *without an LLM turn*", and during that window an LLM turn was being spent
anyway. A green cycle under those conditions measures nothing.

Restarted count: cycle 1 = 22:09Z, cycle 2 = 23:09Z, cycle 3 = 00:09Z, each paired with the `:06`
negative check (origin cron's `last_fired_at` must NOT advance).

## Design notes for whoever extends this

**Silent on success, loud on failure.** The script contacts nobody when it works. That is the whole
point — a cron whose entire job is relaying an exit code should not cost an LLM turn. The alert path
is the only thing that reaches a human or an agent.

**The alert names the origin cron and the rollback.** An alert that says "script failed" leaves the
reader unable to act. This one states which daemon cron it replaced, that the origin is disabled, and
that rollback is re-enabling it — because the failure mode that matters is *nothing is stamping this
agent's heartbeat and nobody knows why*.

**Alerts are sent as the pilot agent, not as devops.** `CTX_AGENT_NAME` is exported so
`cortextos bus` resolves to `reserve` (`src/utils/env.ts:40`). The alert therefore arrives from
`reserve`, which is correct — the failure is reserve's.

## Why user crontab and not systemd

`systemctl --user` on this box returns `Failed to connect to bus: No medium found` despite lingering
being enabled, so there is no user-level systemd instance to own a timer. The user crontab is live
and already carries `sync-oauth-accounts.sh`, so it is a proven path on this host.

**The right long-term home is neither.** `crons.json` should carry an exec-type cron so the daemon
stays the single source of truth. It cannot today: `CronDefinition` (`src/types/index.ts:304+`) has
no `command`/`exec` field, and the only `onFire` implementation
(`src/daemon/agent-manager.ts:1141-1153`) injects into the PTY unconditionally. Adding one is a small
cortextos PR — a schema field plus one branch — and it was queued behind six other items when this
pilot ran.
