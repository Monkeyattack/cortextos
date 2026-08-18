# Class A worksheet — pmo/heartbeat-stamp

Second Lever-1 migration. Chief GO 2026-08-13 (step c). Filled per `PATTERN.md`; **not** copied from
reserve's result — the point of a worksheet is that identical-looking crons get read individually.

| Field | |
|---|---|
| agent / cron | `pmo` / `heartbeat-stamp` |
| schedule | `1h` |
| state at classification | `enabled: true`, `fire_count: 1289`, `last_fired_at: 2026-08-13T01:11:15.921Z` |
| prompt, verbatim | `cortextos bus update-heartbeat "auto-stamp — active session" && cortextos bus update-cron-fire heartbeat-stamp --interval 1h 2>/dev/null \|\| true` |
| prompt md5 | `b0a994cdc7f0` — **byte-identical to the reserve pilot prompt** |

## Why this cron was chosen as the second proof

Agent-independence is the untested generalisation. The pilot proved the pattern on `reserve`; it did
not prove the pattern is not reserve-specific. An **identical prompt on a different agent** isolates
exactly that variable and nothing else.

Eight crons fleet-wide share this byte-identical 144-char prompt (`chief`, `fable-reviewer`, `pmo`,
`project-manager`, `site_manager`, `workspace`, `writer_excision`, `writer_pirate`). **That is the
temptation this worksheet exists to resist** — the batch is available and must not be taken until the
pattern has a second independent proof.

`pmo` specifically: low blast radius. It is a bus-only backend agent with no Telegram channel, so a
heartbeat problem degrades dashboard liveness rather than a human-facing alert path.

## Criteria

| # | Criterion | Verdict | Basis |
|---|---|---|---|
| 1 | No judgment | **yes** | Two fixed `cortextos bus` calls. Nothing to read, decide, classify or summarise. |
| 2 | No state between fires | **yes** | Neither call depends on prior cycles or on what pmo knows. |
| 3 | No args computed at fire time | **yes** | Both arguments are literals: a fixed status string and `--interval 1h`. |
| 4 | Failure expressible as non-zero exit | **yes — BY CONSTRUCTION ONLY** | See below. **Not** true of the bare command. |
| 5 | Success needs no reader | **yes** | The output is a dashboard timestamp. Nobody reads the success case; that is the point. |

### Criterion 4 — how verified, and why the plain answer is NO

**Executed, not assumed** (2026-08-13):

    CTX_AGENT_NAME=no-such-agent-xyz  cortextos bus update-heartbeat "..."
    -> EXIT 0, "Heartbeat updated: no-such-agent-xyz", and a state directory CREATED

So `update-heartbeat` **cannot report mistargeting**. A wrong or unset `CTX_AGENT_NAME` stamps the
wrong agent — or invents one — and exits 0. Genuine execution failures (missing binary) do exit
non-zero, but that is the easy half.

The original prompt is worse than the command: `A && B 2>/dev/null || true` means **the whole
sequence exits 0 even when `A` fails.** The daemon cron as it stands today is fail-open.

**Criterion 4 is satisfied only because the replacement script manufactures the missing signal** —
it captures `last_heartbeat` before the stamp, re-reads after, and fails if it is absent or
unchanged. Same read-back serves as the latency check.

**Without the read-back this cron is NOT Class A.** Recorded that way deliberately: the honest verdict
is conditional, and a future reader must not see a bare "yes".

### Idempotency

**Idempotent — yes.** A second run writes the same `status` string and a newer `last_heartbeat` to
the same file. Two runs converge to one state; nothing is sent, ordered, or appended.

**Transition order: DEFAULT (double-fire-safe), not the idempotent exception.** The carve-out permits
gap-minimising order here, but this is the second-ever migration and the value of a second proof is
that it exercises **the general rule**. If the default ordering has a flaw, it should surface on cron
two, not cron twelve.

### Observable effect (for the latency check)

`~/.cortextos/default/state/pmo/heartbeat.json` → `last_heartbeat` advances.

## Why the per-agent copy is MANDATORY, not ceremony

Chief directed this be recorded here so a future migrator understands the cost of skipping it.

Building this script by copying `reserve-heartbeat-stamp.sh` left **three wrong-agent references**
that a syntax check, a dry run and a success-path test all pass cleanly. One was dangerous:

| Left behind | Why it matters |
|---|---|
| `cortextos bus update-cron **reserve** heartbeat-stamp` in the ROLLBACK instruction | Following it during a **pmo** incident re-enables the wrong agent's cron and leaves pmo dead — while the responder believes they have just rolled back |
| alert text: "the origin cron is DISABLED in **reserve**/crons.json" | An alert that misidentifies the failing agent, read by someone under pressure |
| header: "run **reserve**'s heartbeat-stamp" | Cosmetic, but it is how the other two survived review |

**None of these breaks anything until an incident.** The script runs correctly, stamps the right
agent, and passes its own tests — the wrong-agent text lives only in the comment and the alert body,
i.e. in exactly the material nobody reads until something is already wrong.

That is the argument against batching the eight identical crons: the prompt is byte-identical, so the
copy *looks* free, and the defect it introduces is invisible precisely when it is cheap to find and
catastrophic when it is not.

## Forced-failure test

Required BEFORE go-live. Run on a **copy** with the heartbeat path pointed at a fixture and the bus
write neutered, so the only production write is the alert itself — **which is a production write**,
and saying otherwise was an error made once already tonight.

**PASS**, 2026-08-13 01:31:42Z. Exit 1, alert delivered as pmo (`1786584703392-pmo-z35hr`):

    FAIL read-back: pmo heartbeat timestamp did NOT advance (still 2026-01-01T00:00:00Z)
    despite update-heartbeat exiting 0 — probable mistargeted write; check CTX_AGENT_NAME

Isolation was **gated**, not merely printed: the test aborts unless executable `update-heartbeat`
calls == 0 *and* the heartbeat path resolves under the scratchpad. The alert itself **is** a
production write, stated plainly — a prior test this session claimed "zero production writes" while
sending one.

## Migration result — 3/3

| | Negative check (origin cron must not fire) | Positive (script must stamp) |
|---|---|---|
| cycle 1 | 02:11 slot — `fire_count` 1289 both sources | 02:13:03Z, ~3s |
| cycle 2 | 03:11 slot — `fire_count` 1289 both sources | 03:13:02Z, ~2s |
| cycle 3 | 04:11 slot — `fire_count` 1289 both sources | 04:13:03Z, ~3s |

Every negative check read **both** `crons.json` and the daemon `cron-execution.log` — two writers,
frozen at the same pre-migration values, agreeing to 12ms. Single-source negative checks were the
gap found in the reserve pilot; this migration is the first done to the corrected standard.

**What this proves: agent-independence.** The same prompt, on a second agent, migrated cleanly. That
was the specific untested generalisation pmo was chosen to isolate. It does **not** prove an
unattended week, a daemon restart, a reboot, or crontab survival — see the standing caveat in
`MANIFEST.md`. Three quiet overnight cycles, all watched.

## Blast radius if this migration fails silently

pmo stops being stamped. No Telegram channel is involved. Consequence is dashboard liveness only —
`pmo` would read as stale to anything watching heartbeats, which is a **visible** failure rather than
a silent one, and is why this agent was chosen second rather than a Telegram-carrying agent.
