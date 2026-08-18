#!/usr/bin/env bash
# git-tree-guard.sh — refuse branch-changing git operations in the SHARED working tree.
#
# WHY THIS EXISTS (incident 2026-08-04 19:25Z):
#   Every agent and every worker operates in ONE working tree: /home/claude-dev/cortextos.
#   One tree means one HEAD. A `git checkout` by any agent instantly changes the
#   filesystem under every other running agent and cron — no lock, no warning, no signal.
#   devops ran `git checkout -b feat/bus-ack-on-turn` there; pm was mid-cron and lost a
#   script; chief saw HEAD flip in the reflog.
#
#   The action looked entirely correct at the moment it was taken: create a feature branch
#   for gate-approved work. That is exactly why prose does not hold this — the failure is
#   invisible when you commit it and lands on someone else. So it ships as a fail-closed
#   check instead (AGENTS.md amendment (b), cascaded fleet-wide 2026-08-04).
#
# USAGE
#   guard:  bash git-tree-guard.sh check <git-subcommand> [args...]   -> exit 0 allow, 1 refuse
#   safe:   bash git-tree-guard.sh worktree <name> [committish]       -> make an isolated tree
#
# The `worktree` mode exists so the safe path is CHEAPER than the unsafe one. A prohibition
# that leaves you stuck gets worked around; one that hands you the alternative does not.
set -uo pipefail

SHARED_TREE="/home/claude-dev/cortextos"
WORKTREE_BASE="/tmp/ctx-worktrees"
GIT=/usr/bin/git   # never the wrapped `git` — it emits decorated output, not machine-usable

# Subcommands that move HEAD or rewrite the working tree for EVERY user of it.
BRANCH_CHANGING="checkout switch rebase reset merge cherry-pick revert stash"

log() { echo "[tree-guard] $*"; }

mode="${1:-}"; shift || true

case "$mode" in

  check)
    sub="${1:-}"
    [ -z "$sub" ] && { log "usage: check <git-subcommand> [args...]"; exit 1; }

    here="$($GIT rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [ "$here" != "$SHARED_TREE" ]; then
      log "OK — $here is not the shared tree; '$sub' is your own business."
      exit 0
    fi

    # `checkout -- <path>` and `checkout <tree> -- <path>` restore files without moving HEAD.
    if [ "$sub" = "checkout" ] || [ "$sub" = "switch" ]; then
      for a in "$@"; do [ "$a" = "--" ] && { log "OK — path-restore form, HEAD not moved."; exit 0; }; done
    fi

    if ! printf '%s\n' $BRANCH_CHANGING | grep -qx -- "$sub"; then
      log "OK — '$sub' does not move HEAD in the shared tree."
      exit 0
    fi

    # Who else is live in here right now? Reported, never used to soften the refusal —
    # "nobody else is running" is a race, not a safety property.
    others=$(pgrep -c -f "claude --" 2>/dev/null || echo 0)

    cat <<MSG
[tree-guard] REFUSED: '$sub' in the SHARED working tree.

  tree     : $SHARED_TREE
  branch   : $($GIT rev-parse --abbrev-ref HEAD 2>/dev/null)
  claude procs alive: ${others}

  This tree has ONE HEAD shared by every agent and cron. '$sub' changes the
  filesystem under all of them mid-execution, with no lock and no warning.

  DO THIS INSTEAD — an isolated tree, ~10 seconds:
      bash $0 worktree <name> [committish]

  If you are certain you need it here, a human decides — not a flag on this script.
MSG
    exit 1
    ;;

  worktree)
    name="${1:-}"; committish="${2:-HEAD}"
    [ -z "$name" ] && { log "usage: worktree <name> [committish]"; exit 1; }
    dest="${WORKTREE_BASE}/${name}"

    [ -e "$dest" ] && { log "ERROR: $dest already exists — pick another name or remove it."; exit 1; }
    mkdir -p "$WORKTREE_BASE"

    cd "$SHARED_TREE" || { log "ERROR: cannot cd to $SHARED_TREE"; exit 2; }
    if ! $GIT worktree add -q "$dest" "$committish" 2>&1; then
      log "ERROR: git worktree add failed for $committish"; exit 2
    fi

    # node_modules is ~1GB and identical; symlink rather than install.
    [ -d "${SHARED_TREE}/node_modules" ] && ln -s "${SHARED_TREE}/node_modules" "${dest}/node_modules" 2>/dev/null

    log "ready: $dest  (at $committish, node_modules symlinked)"
    log "cd $dest"
    log "when finished:  $GIT -C $SHARED_TREE worktree remove $dest"
    exit 0
    ;;

  *)
    cat <<MSG
[tree-guard] usage:
  bash $0 check <git-subcommand> [args...]   refuse HEAD-moving ops in the shared tree
  bash $0 worktree <name> [committish]       create an isolated tree (the safe path)
MSG
    exit 1
    ;;
esac
