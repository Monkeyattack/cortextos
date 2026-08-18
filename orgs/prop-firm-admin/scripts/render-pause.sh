#!/usr/bin/env bash
# render-pause.sh — pause renders AND disarm the watcher, as one action.
#
# The mirror of render-resume.sh. See that script's header for why this pair
# exists: on 2026-08-11 renders were paused while render-monitor kept running,
# burning ~288 LLM turns/day watching a pipeline that was not rendering.
#
# Pausing renders without disarming the watcher is the exact failure this
# closes. Run this instead of pausing by hand.
#
# Usage: render-pause.sh [--dry-run]

set -uo pipefail

FLAG=/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/render-monitor/.render-monitor-enabled
TIMER=/home/claude-dev/cortextos/orgs/prop-firm-admin/scripts/render-monitor-timer.sh
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { printf '  %s\n' "$*"; }
echo "render-pause: disarming the render watcher"

if [ "$DRY" -eq 1 ]; then
  say "[dry-run] would remove $FLAG"
  say "[dry-run] would remove crontab lines matching render-monitor-timer.sh"
  exit 0
fi

# 1. Flag off. Removing the file is the OFF state — render-monitor-timer.sh
#    treats an absent flag as disabled, so this is fail-safe even if the
#    crontab removal below fails.
rm -f "$FLAG"
say "flag OFF -> $FLAG removed"

# 2. Timer removed.
current=$(crontab -l 2>/dev/null || true)
if printf '%s\n' "$current" | command grep -q 'render-monitor-timer.sh'; then
  printf '%s\n' "$current" | command grep -v 'render-monitor-timer.sh' | command grep -v '^$' | crontab - 2>/dev/null
  if crontab -l 2>/dev/null | command grep -q 'render-monitor-timer.sh'; then
    echo "render-pause: WARNING — crontab line still present after removal attempt." >&2
    echo "  The flag is off so the watcher will SKIP quietly, but the timer is still firing." >&2
    echo "  Check: crontab -l" >&2
    exit 1
  fi
  say "timer OFF -> crontab line removed, verified absent"
else
  say "timer already absent from crontab — nothing to remove"
fi

# Note the asymmetry, deliberately: the flag alone is sufficient to stop the
# watcher doing anything (the timer would fire and skip). Removing the crontab
# line as well just stops it firing at all. Flag first, so a partial failure
# still lands in the safe state.
echo "render-pause: DONE — renders and watcher are now disarmed together."
