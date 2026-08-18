# Lever 1: moving a Class A cron off LLM turns

Authorised by chief 2026-08-13 after the reserve/heartbeat-stamp pilot returned 3/3.
**This document is the gate for every future migration.** Do not copy a working migration onto a
second cron without walking the worksheet — "it looks like the last one" is the failure this document
exists to prevent.

## What this buys, and what it costs

A daemon cron fires by **PTY injection**: the prompt is typed into the agent's session and the agent
takes a full LLM turn to execute it. For a cron whose prompt is two shell commands with no judgment
in them, that turn buys nothing — and on a deep-context agent it re-reads the whole cached bootstrap
to do it.

The replacement runs the commands directly from the OS scheduler and **stays silent on success**. It
contacts a human or an agent only when something fails.

**The cost is a new failure mode: silence.** A daemon cron that stops firing is visible in the
agent's activity. A crontab line that stops firing is visible nowhere unless you build the visibility.
Everything below is about paying that cost honestly.

## Class A criteria — ALL FIVE must hold

A cron is Class A only if every one of these is true. Any single "no" disqualifies it.

1. **No judgment.** The prompt is a fixed command sequence. It never asks the agent to decide, read,
   summarise, classify, or choose. "Run X and report the output" is NOT Class A — reporting is
   judgment about what matters.
2. **No state carried between fires.** The cron does not depend on what the agent knows, remembers,
   or did last cycle.
3. **No arguments computed at fire time.** Nothing derived from context, conversation, or the
   agent's current work.
4. **Failure is expressible as a non-zero exit.** If a meaningful failure can occur while the
   commands still exit 0, the alert path cannot see it, and migrating hides it. Check this
   specifically — it is the criterion most often assumed rather than verified.
5. **The output does not need to reach a human on success.** If someone reads the result every
   cycle, the turn is doing work and this is not Class A.

**heartbeat-stamp qualifies:** two `cortextos bus` calls, fixed arguments, no state, exit-1 on
failure, and nobody reads the success case — the whole point is a timestamp on a dashboard.

**Counter-example that looks Class A and is not:** the DNS cutover watch. It is one command, no
arguments, no state — but the *exit code selects between three different human-facing actions*, one
of which is messaging Chris. The judgment is in the response, not the invocation.

## The latency check (REQUIRED — chief ruling, 2026-08-13)

**A late-but-successful run must not be silent.** The alert path fires on non-zero exit only, so a
cron that runs 90 seconds late, or whose slot is skipped entirely, is indistinguishable from success.
Pilot cycle 1 completed 96s late and nothing would have reported it.

At one cron that is tolerable. At nineteen it is not, so this ships **with** the pattern, not after it.

**Design:** if the expected positive effect has not landed within **5 minutes** of the expected fire
time, log a warning to the wake-on-alert log. It does **not** need to page — a greppable warning line
is enough, because the point is that a human investigating later can find it.

    <ts> WARN <agent>/<cron> — expected stamp by <due+5m>, last stamp <actual>. Ran late or slot skipped.

The check must key off **the observable effect** (the heartbeat timestamp), not off the script's own
completion — a script that never ran cannot report that it never ran.

## Ordering rule: optimise against DOUBLE-FIRE in both directions

**Chief ruling, 2026-08-13.** Applies to migration *and* rollback — the same principle, mirrored.

**Never let the daemon cron and the replacement script be active at the same time.** Sequence every
transition so the two are never both live, and accept a coverage gap instead.

The two risks are not symmetric:

- **Double-fire takes ACTIONS.** A non-idempotent cron that fires twice sends the Telegram twice,
  checks the trade twice, posts twice. That is active harm and it is not recoverable by waiting.
- **A coverage gap is a silent degradation.** Nothing happens that should not have happened. It is
  worse to detect but it does not *do* anything.

So: gap over double-fire, in both directions.

    MIGRATE:  disable daemon cron -> VERIFY disabled -> install crontab line -> VERIFY installed
    ROLLBACK: remove crontab line -> VERIFY removed  -> enable daemon cron  -> VERIFY it fires

### Exception: idempotent crons MAY minimise the gap instead

If firing twice is genuinely harmless — the cron writes a timestamp, sets a value, or is otherwise
naturally idempotent — the order may be reversed to keep coverage continuous.

**`heartbeat-stamp` is idempotent:** stamping the same heartbeat twice writes the same field twice
and produces one state. The 2026-08-13 restore used the gap-minimising order on that basis, which
this exception permits — but it was chosen before this rule existed, and the general case is the
rule above.

**Idempotency is a per-cron judgement and it goes in the worksheet.** Do not infer it from the cron
looking simple: "runs a script and exits" says nothing about what the script does on a second run.

## Rollback procedure — FAIL-CLOSED ORDER

**The first version of this procedure half-applied during the drill and recreated the double-fire
fault.** Step 1 silently did nothing while step 2 succeeded. Order and verification are not
ceremony here.

    # 1. Remove the crontab line. Use STDIN — `crontab <path>` is length-sensitive
    #    on this box and FAILS on long paths (this is how the drill broke).
    crontab -l | /usr/bin/grep -v 'LEVER1-PILOT' | crontab -

    # 2. VERIFY IT LANDED. This is a GATE, not a check.
    crontab -l | /usr/bin/grep -c 'LEVER1-PILOT'

### ⛔ HARD ABORT: if the crontab line is not confirmed gone, do not touch the daemon cron

If step 2 prints anything other than `0`, **stop**. Do not run step 3. Do not "try it anyway."
Fix step 1 and re-verify first.

Enabling the daemon cron while the crontab line is still installed puts the agent in **double-fire**
— an LLM turn *and* the script, every cycle. That is the precise fault this whole pattern exists to
remove, and during the drill it was reintroduced for 19 seconds by exactly this sequence. No fire
slot happened to fall inside that window. That was luck.

    # 3. ONLY after step 2 prints 0.
    cortextos bus update-cron <agent> <cron> --enabled true

**4. YOU ARE NOT COVERED YET. Record the current `fire_count` as your baseline.**

    python3 -c "import json;d=json.load(open('$HOME/.cortextos/default/.cortextOS/state/agents/<agent>/crons.json'));\
    print([c for c in (d if isinstance(d,list) else d['crons']) if c['name']=='<cron>'][0]['fire_count'])"

**5. VERIFY THE FIRE. Do not declare the agent covered until `fire_count` has advanced past the
step-4 baseline.** Re-enabling schedules the cron; it does not fire it. Until you have seen the
count move, nothing is stamping this agent and no alert will tell you so.

Cross-check against the daemon's own execution log, which is a different writer:

    /usr/bin/grep '<cron>' ~/.cortextos/default/.cortextOS/state/agents/<agent>/cron-execution.log | tail -2

### How long step 5 takes — re-enabling does NOT restore coverage

The catch-up gate suppresses long-missed slots — it will not fire a burst to catch up.

**Measured in the 2026-08-13 drill: re-enabled 00:12:04Z, first daemon fire 01:09:15Z — a
57-MINUTE UNCOVERED GAP** on a 1-hour cron. That is not "a fraction of an interval"; it is
effectively the whole interval. The earlier wording here said "up to one full interval", which read
as a hedge. It is not a hedge — assume you lose the full interval.

**Incident responders must not treat re-enable as restoration.** Re-enable schedules; it does not
fire. This is the failure mode where someone rolls back during an outage, sees `enabled: true`, and
walks away from an agent that will not be stamped for another hour.

**Never hand-edit `crons.json` to enable or disable.** It changes nothing until the daemon is
signalled — see `../../knowledge/devops/cron-disable-requires-daemon-reload.md`.

## ⚠️ `list-crons` IS NOT AN AUTHORITATIVE HEALTH SURFACE FOR LEVER-1 CRONS

**Do not audit migration health from `list-crons`. It cannot distinguish a healthy migrated cron
from a dead one.**

This is the most significant fleet-wide finding of the rollback drill, and it gets worse as more
crons migrate.

`cortextos bus list-crons` merges `crons.json.last_fired_at` with the fire records in
`cron-state.json` via `mostRecent()` (`src/cli/bus.ts:2190`). The replacement script calls
`update-cron-fire` itself, which writes a fire record.

**So a migrated cron displays as firing normally on schedule, whether the migration is working or
completely dead.** Throughout the pilot, `list-crons` showed `heartbeat-stamp` last-firing on time
while the daemon cron was disabled and had not fired once.

Auditing Lever-1 crons from that surface will show N healthy crons and tell you nothing.

**The wake-on-alert log is the ONLY source that distinguishes daemon-fired from script-fired.**

    /home/claude-dev/.cortextos/<instance>/logs/<agent>/wake-on-alert.log

Every migration adds one more cron that looks healthy on the surface most people check, and whose
real state lives somewhere else. That asymmetry is the standing cost of this pattern — it is the
price of the LLM turns it saves, and it should be quoted whenever the saving is.

## ⚠️ The alert path freshens the heartbeat it is complaining about

**Any bus event bumps `last_heartbeat`.** Confirmed at source 2026-08-13:
`bus send-message` → `logEvent(...)` (`src/cli/bus.ts:70`) → `refreshHeartbeatTimestamp`
(`src/bus/event.ts:68-86`), which rewrites `last_heartbeat` and preserves every other field.

So when this script's read-back fails and it alerts, **the alert itself makes the agent's heartbeat
look fresh.** An agent whose stamping is completely broken will keep appearing healthy to any
liveness monitor, *because* it keeps reporting that it is broken.

Observed twice before it was explained — reserve `01:22:51Z` and pmo `01:31:43Z`, each within a
second of a forced-failure alert, status text unchanged in both.

**This does NOT break the read-back.** The comparison is `before` → stamp → `after` inside one run,
and the alert fires only after the decision. On the following cycle `before` is the alert-bumped
value, so a still-broken stamp still yields `after == before` and still fails. The mechanism is safe.

**What it breaks is everything outside this script.** Heartbeat freshness is not evidence that an
agent's heartbeat cron works — it is evidence that the agent did *something* on the bus. For a
Lever-1 migrated cron, that "something" may be the alert saying it is failing.

**Consequences to hold onto:**

- Never use heartbeat freshness to audit a Lever-1 migration. Use the `wake-on-alert` log.
- This compounds the `list-crons` blind spot above. Both of the obvious health surfaces —
  `list-crons` and heartbeat freshness — show a dead migrated cron as healthy, for two unrelated
  reasons.
- It is fleet-wide, not Lever-1-specific: *any* agent that logs events looks alive.

## Pick the minute deliberately — this box is 8 cores

**Give every migrated cron its own minute-of-hour, offset from the existing cluster.** Record the
choice in `MANIFEST.md` so the next migration can see what is taken.

In use so far: `:09` reserve, `:11` writer (daemon), `:13` pmo, `:19` workspace. Daemon-cron offsets already in fleet
use include `:07` devops, `:17` lit, `:23` chief, `:37` notes, `:53` braindump.

**Why this is not fussiness.** The host has **8 cores** and carries ~32 interactive agent processes.
Load averages of 100+ have been measured — roughly 12x oversubscription per core — and at that level
a job that normally takes 3 seconds took **96 seconds** (pilot cycle 1, 2026-08-12 22:10Z). It
completed, and nothing reported the delay, because the alert path keys on exit code.

Stacking N migrated crons on the same minute manufactures exactly the contention that produces those
outliers, and the latency check is the only thing that would notice. Spread them.

**Corollary for the rollout:** migrating nineteen crons onto `:00` because it is tidy would convert a
diffuse load into a spike once an hour, on the box that is already the constraint.

## Classification worksheet — one per cron, written down

Do not migrate from memory or by analogy. For each candidate, record:

| Field | |
|---|---|
| agent / cron name | |
| schedule | |
| prompt, verbatim | |
| criterion 1 — no judgment | yes/no + why |
| criterion 2 — no state | yes/no + why |
| criterion 3 — no computed args | yes/no + why |
| criterion 4 — failure is non-zero exit | yes/no + **how verified** |
| criterion 5 — success needs no reader | yes/no + why |
| **IDEMPOTENT?** — is firing twice harmless? | yes/no + **what a second run actually does** |
| → therefore transition order | double-fire-safe (default) / gap-minimising (idempotent only) |
| what the observable effect is (for the latency check) | |
| forced-failure test result | must be run BEFORE go-live |

**Criterion 4 gets "how verified", not "yes".** The others can be read off the prompt; this one is a
behavioural claim and behavioural claims get executed.

## Go-live checklist

1. Worksheet complete, all five criteria yes.
2. Script written; **silent on success**, alerts on failure, alert names the origin cron and the
   rollback.
3. **Forced-failure test executed** — break the command deliberately, confirm the alert actually
   arrives. Run it on a COPY so there is nothing to restore.
4. Latency check in place, keyed to the observable effect.
5. Origin cron disabled via `bus update-cron --enabled false` (never a hand-edit).
6. **Negative check — READ BOTH SOURCES.** Confirm one full interval later that the origin cron did
   not fire. A disable is proven by an absence of a fire, never by the file saying `enabled: false`.

       # source A — crons.json: last_fired_at and fire_count must be UNCHANGED
       # source B — the daemon's own execution log, a DIFFERENT writer:
       /usr/bin/grep '<cron>' ~/.cortextos/default/.cortextOS/state/agents/<agent>/cron-execution.log | tail -2

   **Both, not either.** The pilot's three negative checks all read source A alone. They were
   correct — the execution log confirmed them afterwards, 978 entries with none in the pilot window
   — but that was luck, not method: had `crons.json` itself been wrong, all three checks would have
   agreed with each other and with nothing. Two writers, two files, or it is one check repeated.
7. MANIFEST.md row added: timer, origin cron, authorisation, rollback.
8. Three unattended cycles before it counts as migrated.

## Standing constraints (chief, 2026-08-13)

- **N=3 is small.** The first cron to show a failed unattended cycle **stops the rollout** until
  investigated. GO is not "keep going regardless."
- **Every cron gets its own read.** Nineteen agents may all carry an identical `heartbeat-stamp` —
  fine, write the worksheet out for each anyway.
- **The rollback must stay a demonstrated capability.** It has been wrong twice: once in mechanism,
  once only visible on execution. Re-drill it if the procedure changes.

## Related

`MANIFEST.md` (live timer→origin-cron map) · `reserve-heartbeat-stamp.sh` (reference
implementation) · `../../knowledge/devops/cron-disable-requires-daemon-reload.md`
