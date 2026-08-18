#!/usr/bin/env bash
# render-monitor-timer.sh — run the render watcher WITHOUT waking an LLM agent.
#
# WHY
# ---
# render-monitor ran a */5 cron that woke a full agent turn to read deterministic
# script output: ~288 LLM turns/day producing nothing a shell could not do.
# Removed by fable-reviewer 2026-08-11 during a token emergency (37% of the
# weekly budget spent in the first 24h post-reset).
#
# The agent was never needed: render-monitor.mjs is SELF-DELIVERING. Verified by
# reading it — 343 lines, two sendTelegram() call sites, its own dedup file
# (/tmp/render-monitor-alerted.json) with per-job TTL, nine console.error
# diagnostics to stderr, three explicit process.exit(0) and ZERO exit(1). It
# decides its own alert conditions (quota block, stale rendering jobs, recent
# failures, failure-rate spike) and sends its own Telegram. Nothing needs to
# parse its output or judge an alert line.
#
# THE COUPLING THAT WAS MISSING
# -----------------------------
# Renders were paused; the watcher kept running anyway and burned turns watching
# nothing. That decoupling is the actual defect, not the cron interval. So this
# wrapper GATES on renders being active and exits 0 quietly when they are not —
# pausing renders now pauses the watcher, without anyone remembering to.
#
# Gate: RENDER_MONITOR_ENABLED=1 in the flag file, default OFF. Deliberately
# opt-IN: the failure we are fixing is a watcher that ran when it should not
# have, so the safe default is not running. Renders resume -> flip the flag.
#
# Usage:  render-monitor-timer.sh [--force]     --force ignores the gate (manual test)
# Exit:   0 always, unless the script itself is missing (2). A monitor that
#         crashes a timer is a monitor that gets disabled.

set -uo pipefail

MJS=/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/render-monitor/scripts/render-monitor.mjs
ENV_FILE=/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/render-monitor/.env
FLAG_FILE="${RENDER_MONITOR_FLAG:-/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/render-monitor/.render-monitor-enabled}"
LOG=/home/claude-dev/.cortextos/default/logs/render-monitor/timer.log
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$(dirname "$LOG")" 2>/dev/null
stamp() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

if [ ! -f "$MJS" ]; then
  stamp "FATAL script missing: $MJS"
  echo "render-monitor-timer: $MJS not found" >&2
  exit 2
fi

# ── Gate ─────────────────────────────────────────────────────────────────────
if [ "$FORCE" -eq 0 ]; then
  enabled=0
  if [ -f "$FLAG_FILE" ]; then
    # Any line RENDER_MONITOR_ENABLED=1 turns it on. Absent file or any other
    # value means off.
    while IFS= read -r line; do
      case "$line" in RENDER_MONITOR_ENABLED=1*) enabled=1 ;; esac
    done < "$FLAG_FILE"
  fi
  if [ "$enabled" -ne 1 ]; then
    stamp "SKIP renders not active (flag off) — this is the coupling that was missing on 2026-08-11"
    exit 0
  fi
fi

# ── Run ──────────────────────────────────────────────────────────────────────
# The script sends its own Telegram alerts. We capture stderr for ops history
# and never act on it, so no LLM turn is spent reading output.
start=$(date -u +%s)
out=$(cd "$(dirname "$MJS")" && \
      { [ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a; }; \
      node "$MJS" 2>&1)
rc=$?
dur=$(( $(date -u +%s) - start ))

# Keep the tail only — this runs every 5 minutes and the log should stay
# readable a month from now.
stamp "run rc=$rc ${dur}s :: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"

# Trim to the last 2000 lines so an every-5-minutes timer cannot fill a disk.
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
  tail -2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# Deliberately exit 0 even on a non-zero rc: the alert path is the script's own
# Telegram, not this wrapper's exit status, and a systemd timer that keeps
# failing gets muted by whoever is on call.
exit 0
