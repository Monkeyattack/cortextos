#!/usr/bin/env bash
# render-resume.sh — resume renders AND arm the watcher, as one action.
#
# WHY THIS EXISTS
# ---------------
# 2026-08-11: renders were paused, and render-monitor kept running anyway —
# ~288 LLM turns/day watching a pipeline that was not rendering, during a token
# emergency (37% of the weekly budget in the first 24h post-reset).
#
# The defect was not the cron interval. It was that pausing renders and
# disarming the watcher were two separate acts, so one could happen without the
# other. There was no resume script, no pause script and no runbook step — the
# two halves were held together by memory alone, and memory is what failed.
#
# So: resuming renders and arming the watcher are now ONE command. Same for
# render-pause.sh in the other direction.
#
# The watcher itself is fail-safe regardless: render-monitor-timer.sh defaults
# to OFF and skips quietly when the flag is absent. If someone resumes renders
# by editing config instead of running this, the failure mode is a QUIET WATCHER
# — the cheap error, deliberately chosen over a watcher that burns turns.
#
# Usage: render-resume.sh [--dry-run]

set -uo pipefail

FLAG=/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/render-monitor/.render-monitor-enabled
TIMER=/home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/render-monitor-timer.sh
CRON_LINE="*/5 * * * * $TIMER >/dev/null 2>&1"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { printf '  %s\n' "$*"; }
echo "render-resume: arming the render watcher"

if [ ! -x "$TIMER" ]; then
  echo "render-resume: FAILED — $TIMER missing or not executable." >&2
  echo "  Renders may be resumed, but the watcher is NOT armed. Fix this before relying on alerts." >&2
  exit 1
fi

if [ "$DRY" -eq 1 ]; then
  say "[dry-run] would write RENDER_MONITOR_ENABLED=1 to $FLAG"
  say "[dry-run] would install crontab line: $CRON_LINE"
  exit 0
fi

# 1. Flag on.
printf 'RENDER_MONITOR_ENABLED=1\n# armed by render-resume.sh %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FLAG"
say "flag ON  -> $FLAG"

# 2. Timer installed, idempotently. Existing line is replaced, not duplicated.
current=$(crontab -l 2>/dev/null || true)
filtered=$(printf '%s\n' "$current" | command grep -v 'render-monitor-timer.sh' || true)
printf '%s\n%s\n' "$filtered" "$CRON_LINE" | command grep -v '^$' | crontab - 2>/dev/null
if crontab -l 2>/dev/null | command grep -q 'render-monitor-timer.sh'; then
  say "timer ON -> */5 * * * * (crontab, verified present)"
else
  echo "render-resume: WARNING — crontab install could not be verified." >&2
  echo "  The flag is on but the timer may not be scheduled. Check: crontab -l" >&2
  exit 1
fi

# 3. Prove it works rather than asserting it.
say "verifying with one real run..."
if "$TIMER" >/dev/null 2>&1; then
  say "verify OK — watcher ran and exited clean"
else
  echo "render-resume: WARNING — first run returned non-zero. Check the timer log." >&2
fi
say "log: /home/claude-dev/.cortextos/default/logs/render-monitor/timer.log"
echo "render-resume: DONE — renders and watcher are now armed together."
