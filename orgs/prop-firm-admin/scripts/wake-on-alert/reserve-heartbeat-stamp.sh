#!/usr/bin/env bash
# reserve-heartbeat-stamp.sh — Lever 1 pilot: run reserve's heartbeat-stamp WITHOUT an LLM turn.
#
# ORIGIN CRON (disabled, not deleted — rollback is re-enable):
#   agent   reserve
#   name    heartbeat-stamp
#   sched   1h
#   prompt  cortextos bus update-heartbeat "auto-stamp — active session" \
#             && cortextos bus update-cron-fire heartbeat-stamp --interval 1h 2>/dev/null || true
#   fire_count at handover: 976
#
# DISABLING THE ORIGIN CRON: use `cortextos bus update-cron reserve heartbeat-stamp
# --enabled false`, NEVER a hand-edit of crons.json. `enabled` is read only in
# loadCrons() (cron-scheduler.ts:370), reachable only via IPC reload; there is no
# file watcher. A hand-edited disable leaves the in-memory schedule firing — that
# happened here on 2026-08-12 and double-ran the pilot for an hour. See MANIFEST.md.
#
# WHY: a daemon cron fires by PTY injection = one full LLM turn, and each turn on a
# deep-context agent re-reads the whole cached bootstrap. This prompt is two bash
# commands with zero judgment, so the turn buys nothing. ~19 agents x 12-24 fires/day
# is the Class A population this pilot represents.
#
# WAKE-ON-ALERT: this script does the work directly and stays SILENT on success.
# It contacts a human/agent ONLY when something fails. Session injection is reserved
# for judgment, never for relaying a script's exit code.
#
# WHY user crontab and not systemd: `systemctl --user` on this box returns
# "Failed to connect to bus: No medium found" despite lingering being enabled, so
# there is no user-level systemd instance to own a timer. The user crontab is live
# and already carries sync-oauth-accounts.sh. An exec-type cron in crons.json would
# be the right home for this, but CronDefinition has no command field and the only
# onFire implementation (agent-manager.ts:1141) injects into the PTY unconditionally
# — adding one is a cortextos PR, which could not ship in this window.

set -uo pipefail

AGENT="reserve"
export CTX_AGENT_NAME="$AGENT"          # resolveEnv() reads this — utils/env.ts:40
export CTX_INSTANCE_ID="${CTX_INSTANCE_ID:-default}"
export CTX_ORG="${CTX_ORG:-prop-firm-admin}"

LOG="/home/claude-dev/.cortextos/${CTX_INSTANCE_ID}/logs/${AGENT}/wake-on-alert.log"
mkdir -p "$(dirname "$LOG")"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

fail() {
  # The ONLY path that contacts anyone. Alerts must be loud and must name the
  # origin cron, or an operator sees a failure with no idea what used to do this.
  local what="$1" detail="$2"
  echo "$(ts) FAIL ${what}: ${detail}" >> "$LOG"
  cortextos bus send-message chief high \
    "wake-on-alert FAILURE — ${AGENT}/heartbeat-stamp (Lever 1 pilot). Step '${what}' failed: ${detail}. This replaced a daemon cron that fired by LLM injection; the origin cron is DISABLED in reserve/crons.json, so ${AGENT}'s heartbeat is NOT being stamped by anything else. Rollback = re-enable that cron." \
    2>>"$LOG" || echo "$(ts) ALERT-SEND-FAILED — both the work and the alert failed" >> "$LOG"
  exit 1
}

HEARTBEAT_FILE="/home/claude-dev/.cortextos/${CTX_INSTANCE_ID}/state/${AGENT}/heartbeat.json"

# IDENTITY PIN — must run BEFORE the stamp.
#
# The delta read-back below was documented as closing the mistargeting hole. It does
# not, and this was proven by test on 2026-08-14: running with AGENT set to a name
# that does not exist exits 0 and logs "OK heartbeat stamped". update-heartbeat
# CREATES the agent directory, so `after` is populated, differs from an empty
# `before`, and the delta check passes. The delta proves a write HAPPENED; it can
# never prove the write hit the right SUBJECT, because the wrong subject is brought
# into existence by the very call being checked.
#
# Pinning `agent` inside heartbeat.json does not help either — update-heartbeat
# writes that field from the same wrong name, so it agrees with itself.
#
# What actually discriminates: a real agent that is stamped hourly ALWAYS already has
# a heartbeat.json. If this file does not exist before the stamp, the name is wrong
# (typo, unset variable, renamed agent) and continuing would silently manufacture a
# phantom agent while reporting success.
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
  echo "$(ts) FAIL identity-pin: no heartbeat.json at ${HEARTBEAT_FILE} before stamping — AGENT='${AGENT}' does not name a live agent in instance '${CTX_INSTANCE_ID}'. Refusing to stamp; continuing would create a phantom agent and report success." >> "$LOG"
  cortextos bus send-message chief high \
    "wake-on-alert FAILURE — ${AGENT}/heartbeat-stamp: identity pin refused to stamp. No heartbeat.json exists for '${AGENT}' in instance '${CTX_INSTANCE_ID}', so this script is pointed at an agent that does not exist. Nothing is stamping that agent. Check AGENT in the script and the crontab line." \
    2>>"$LOG" || echo "$(ts) ALERT-SEND-FAILED — identity pin failed and the alert failed" >> "$LOG"
  exit 1
fi

# Timestamp BEFORE the stamp, so the read-back below has something to compare against.
before=$(python3 -c "
import json,sys
try: print(json.load(open('${HEARTBEAT_FILE}')).get('last_heartbeat') or '')
except Exception: print('')" 2>/dev/null)

out=$(cortextos bus update-heartbeat "auto-stamp — active session" 2>&1) \
  || fail "update-heartbeat" "${out:-no output}"

# READ-BACK VERIFICATION — exit 0 is NOT proof the right agent was stamped.
#
# `cortextos bus update-heartbeat` returns 0 and prints "Heartbeat updated: <name>"
# even for an agent that does not exist — it simply creates the directory. So a wrong
# or unset CTX_AGENT_NAME stamps the WRONG agent, or invents one, and reports success.
# Measured 2026-08-13:
#     CTX_AGENT_NAME=no-such-agent-xyz cortextos bus update-heartbeat "..." -> exit 0
# Mistargeting is therefore invisible to an exit-code check, and this script's entire
# alert path keys off exit codes. Verifying the EFFECT is the only thing that closes it.
#
# This same read-back is the latency check: if the stamp did not land, we are late or
# dead, and either way it must not be silent. One mechanism, two problems.
after=$(python3 -c "
import json,sys
try: print(json.load(open('${HEARTBEAT_FILE}')).get('last_heartbeat') or '')
except Exception: print('')" 2>/dev/null)

if [[ -z "$after" ]]; then
  fail "read-back" "${AGENT} heartbeat.json unreadable or has no last_heartbeat after a successful stamp — the write did not land where it should have"
fi
if [[ "$after" == "$before" ]]; then
  fail "read-back" "${AGENT} heartbeat timestamp did NOT advance (still ${before}) despite update-heartbeat exiting 0 — probable mistargeted write; check CTX_AGENT_NAME"
fi

# Origin prompt tolerated failure here (2>/dev/null || true). Kept non-fatal for
# behavioural parity — this call only registers the fire so the gap-detector stops
# nudging; losing it does not stop the heartbeat itself.
cortextos bus update-cron-fire heartbeat-stamp --interval 1h >>"$LOG" 2>&1 || \
  echo "$(ts) WARN update-cron-fire failed (non-fatal, matches origin prompt)" >> "$LOG"

echo "$(ts) OK heartbeat stamped for ${AGENT}" >> "$LOG"
exit 0
