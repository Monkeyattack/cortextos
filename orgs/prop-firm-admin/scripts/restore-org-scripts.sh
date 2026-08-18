#!/usr/bin/env bash
# restore-org-scripts.sh — ensure org-local scripts are present after daemon restart
# These files are git-tracked on fix/cron-scheduler-injection-stagger but are org-specific
# and should never merge to upstream cortextos/main. This script restores them from git.
#
# Run automatically on session start (AGENTS.md step 3.5).

set -euo pipefail

REPO_ROOT="/home/claude-dev/cortextos"
ORG_ROOT="${REPO_ROOT}/orgs/prop-firm-admin"

# Restore source, in priority order.
#
# This was hardcoded to a single branch (fix/cron-scheduler-injection-stagger)
# and silently rotted: by 2026-08-12 active work had moved two branches on, so
# the script would "restore" a missing file to a version over a week stale, and
# anything first tracked on a later branch could not be restored at all. A
# restore path that reaches for a branch nobody works on is worse than no
# restore path, because it reports success.
#
# Derive the current branch instead, and keep the historical branch only as a
# fallback for files that predate the move and were never re-committed since.
# Override with RESTORE_BRANCH=<ref> for a one-off restore from a known-good ref.
CURRENT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
LEGACY_BRANCH="fix/cron-scheduler-injection-stagger"

RESTORE_REFS=()
[[ -n "${RESTORE_BRANCH:-}" ]] && RESTORE_REFS+=("${RESTORE_BRANCH}")
[[ -n "${CURRENT_BRANCH}" && "${CURRENT_BRANCH}" != "HEAD" ]] && RESTORE_REFS+=("${CURRENT_BRANCH}")
RESTORE_REFS+=("${LEGACY_BRANCH}")

log() { echo "[restore-org-scripts] $(date -u +%Y-%m-%dT%H:%M:%SZ)  $*"; }

MISSING=0
FAILED=0

check_file() {
    local path="$1"
    if [[ ! -f "${REPO_ROOT}/${path}" ]]; then
        log "MISSING: ${path} — restoring from git"
        cd "${REPO_ROOT}"
        MISSING=$((MISSING + 1))
        local ref
        for ref in "${RESTORE_REFS[@]}"; do
            if git checkout "${ref}" -- "${path}" 2>/dev/null; then
                # Name the ref actually used. The old version logged a bare
                # "restored" and left you to assume it came from somewhere
                # current — which is exactly how a stale restore passes for a
                # good one.
                log "restored: ${path}  (from ${ref})"
                [[ "${ref}" == "${LEGACY_BRANCH}" ]] && \
                    log "  NOTE: served from the legacy branch — ${path} is not committed on ${CURRENT_BRANCH:-HEAD}"
                return 0
            fi
        done
        log "ERROR: could not restore ${path} from any of: ${RESTORE_REFS[*]}"
        FAILED=$((FAILED + 1))
    fi
}

# Org-local scripts (not in upstream/main)
check_file "orgs/prop-firm-admin/scripts/h137-premarket-check.sh"
check_file "orgs/prop-firm-admin/scripts/h137-monitor.sh"
check_file "orgs/prop-firm-admin/scripts/nt8-pipeline-check.sh"
check_file "orgs/prop-firm-admin/guards/verify-stamp.sh"

# REMOVED 2026-08-12 (chief ruling, option c on task_1785817418885_18tgp8):
#   orgs/prop-firm-admin/scripts/query-trades.sh
#   orgs/prop-firm-admin/scripts/ct-time.sh
# Both were listed here for months and are tracked on NEITHER branch, so this
# script could never restore them. Before the fail-closed change they were
# "restored" with exit 0 and every session-start run reported a clean boot.
# Listing a file this net cannot actually restore creates false confidence,
# which is worse than an honest gap — so the list now claims only what it can
# deliver. Both files are still present on disk and still in use; they simply
# have no restore coverage and never did.
# If either is judged load-bearing enough to survive a wipe, that is a separate
# architectural decision (move it to a tracked path outside the gitignored
# orgs/ tree) and needs its own task — do NOT solve it by adding the filename
# back here.

if [[ $MISSING -eq 0 ]]; then
    log "all org-local scripts present"
else
    log "restored $((MISSING - FAILED)) of ${MISSING} missing file(s)"
fi

# Fail closed. This runs at session start to guarantee the org's operational
# scripts exist; a script that cannot restore one and still exits 0 hands the
# session a missing monitor and calls it a clean boot.
if [[ $FAILED -gt 0 ]]; then
    log "FAILED to restore ${FAILED} file(s) — exiting non-zero"
    exit 1
fi
