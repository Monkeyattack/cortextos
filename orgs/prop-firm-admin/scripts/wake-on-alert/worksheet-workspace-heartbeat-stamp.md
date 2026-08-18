# Class A worksheet — workspace/heartbeat-stamp

Third Lever-1 migration. Chief fleet-rollout GO 2026-08-13 04:25Z, after fable-reviewer gate PASS.
Filled per `PATTERN.md`. **Not** copied from the pmo result.

| Field | |
|---|---|
| agent / cron | `workspace` / `heartbeat-stamp` |
| schedule | `1h` |
| state at classification | `enabled: true`, `fire_count: 1206` |
| prompt md5 | `b0a994cdc7f0` — byte-identical to reserve and pmo |
| crontab minute | `:19` — `:09` reserve, `:13` pmo taken; `:07/:11/:17/:23/:37/:53` are daemon-cron offsets |

## Why workspace, and why only one this session

**Cron 3 is the highest-information migration in the whole rollout.** Chief's framing: a pattern flaw
should surface here, not on cron 19. Reserve proved the mechanism, pmo proved agent-independence;
this one tests whether the *documented procedure* survives being followed by someone working from
the doc rather than from memory of building it.

`workspace` chosen for low blast radius, and deliberately **not** `chief` or `fable-reviewer` — I
depend on both for rulings and gates, and their heartbeats should not be the thing I experiment with.

**Stopping at one this session, deliberately.** Chief permits 2–3. The pmo copy required **three**
wrong-agent corrections that every automated check passed, and that was earlier in the session with
more headroom. Migration 4+ at this point is exactly where that class of error stops being caught.
The remaining seven are not urgent enough to spend that risk on.

## Criteria

| # | Criterion | Verdict | Basis |
|---|---|---|---|
| 1 | No judgment | **yes** | Two fixed `cortextos bus` calls; nothing read, decided or summarised |
| 2 | No state between fires | **yes** | Neither call depends on prior cycles |
| 3 | No args computed at fire time | **yes** | Literals only: fixed status string, `--interval 1h` |
| 4 | Failure expressible as non-zero exit | **yes — BY CONSTRUCTION ONLY** | see below |
| 5 | Success needs no reader | **yes** | Output is a dashboard timestamp |

### Criterion 4 — how verified

The bare command **fails this criterion**. Established by execution 2026-08-13 (not re-run here — the
finding is about `cortextos bus update-heartbeat` itself, not about any one agent):

    CTX_AGENT_NAME=no-such-agent-xyz  cortextos bus update-heartbeat "..."  ->  EXIT 0

Mistargeting is invisible to an exit-code check. The original prompt is worse still —
`A && B 2>/dev/null || true` exits 0 even when `A` fails, so the daemon cron is fail-open today.

**Satisfied only because the replacement script manufactures the missing signal** (read-back of
`last_heartbeat` before/after). **Without the read-back this cron is NOT Class A.**

**Known open defect in that read-back**, carried knowingly into this migration: `last_heartbeat` has
one-second resolution, so a prior write landing in the same second (realistically an alert-bumped
heartbeat via `event.ts:68`) yields `before == after` and a false alarm. It **fails loud, not open**.
fable-reviewer's pre-decided fix direction is *inconclusive-and-retry-once*, not sub-second precision
— sub-second would change what `update-heartbeat` writes fleet-wide to fix a per-script comparison,
which is the wrong blast radius. To be filed as its own change post-freeze.

### Idempotency

**Idempotent — yes.** A second run rewrites the same status string and a newer timestamp to one file;
nothing is sent, ordered or appended.

**Transition order: DEFAULT double-fire-safe**, not the idempotent carve-out — same reasoning as pmo.

### Observable effect

`~/.cortextos/default/state/workspace/heartbeat.json` → `last_heartbeat` advances.

## Blast radius if this fails silently

workspace stops being stamped; dashboard liveness only, no Telegram path. Visible as staleness —
except that heartbeat freshness is **not** a reliable surface here (any bus event bumps it) and
`list-crons` is not either (the script writes its own fire record). **The `wake-on-alert` log is the
only place a failure shows.**

## Results

Forced-failure, migration and cycles recorded below at execution time.

## Migration result — 3/3

| | Negative (origin cron must not fire) | Positive (script must stamp) |
|---|---|---|
| cycle 1 | 05:11 slot — see note below | 05:19:02Z, ~2s |
| cycle 2 | 06:11 slot — both sources | 06:19:02Z, ~2s |
| cycle 3 | 07:11 slot — both sources | 07:19:02Z, ~2s |

Source A: `crons.json` `fire_count` frozen at 1206, `last_fired_at` 04:11:38.801Z.
Source B: daemon `cron-execution.log` last entry 04:11:38.810Z — predates the 04:27:23Z migration.
The two agree to 9ms on the same last-fire event and neither moved across three slots.

### Cycle 1's source B was invalid as written — disclosed, not buried

The original check compared execution-log **entry count** against `crons.json` `fire_count` (1206).
Those are not comparable: **the execution log rotates** (`MAX_LOG_LINES`, `cron-execution-log.ts`),
so workspace's log holds 905 heartbeat-stamp entries against a `fire_count` of 1206. The assertion
was meaningless and cycle 1 was effectively **single-source** — the exact deficiency dual-source
exists to remove.

It passed for pmo only because that log had not yet rotated (1289 == 1289). **Accidental validity,
not method**, and it surfaced only because workspace's log had rotated.

Cycle 1 still stands: source B was re-derived correctly by hand afterwards (last entry
04:11:38.810Z < migration 04:27:23Z). But *passed* and *passed by a method that would have caught
the failure* are different claims, and cycles 2 and 3 are the first here where both assertions were
valid as written.

**Corrected standard, now fleet-wide (chief, 2026-08-13):** source B asserts that the **last
execution-log entry predates the migration**. Rotation-proof. The count comparison is retired.

`PATTERN.md` was never wrong — it prescribes `tail -2`, a timestamp view, and never mentions counts.
I invented the count comparison while believing I was following my own procedure. That is
**under-specification**: the step showed the command without stating the assertion, so I supplied my
own. Fix queued — make the assertion explicit, with the count comparison named as an anti-pattern.
