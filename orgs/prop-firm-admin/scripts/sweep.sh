#!/usr/bin/env bash
# sweep.sh — a fleet search whose count you are allowed to quote.
#
# WHY THIS EXISTS
# ---------------
# `grep` in a Claude Code shell is a bash FUNCTION that execs ugrep, not GNU
# grep. Verify it yourself right now:
#
#     type grep                     -> "grep is a function"
#     grep --version                -> ugrep 7.5.0
#     command grep --version        -> grep (GNU grep) 3.11
#
# The two disagree on identical queries, reproducibly, and BOTH EXIT 0 WITH
# EMPTY STDERR. Measured 2026-08-11 in two independent agent environments:
# 74 vs 245 files in one, 49 vs 133 in the other. Nothing in the output, the
# exit code, or stderr tells you which you got.
#
# Four separate incidents landed that day, one of them inside a guard written
# minutes earlier:
#   * a fleet audit that concluded "no call sites exist" off a partial result
#   * `grep -h` hitting the shim where -h means HELP, piping 925 chars of help
#     text into a variable that was supposed to hold a token
#   * a FRED download validator rejecting a good file because `grep -qi VIXCLS`
#     failed against a header literally reading `observation_date,VIXCLS`
#   * a `comm` diff reporting two file lists identical when they differed by 171
#
# The direction is what makes it dangerous: a partial result returns FEWER hits,
# so the failure mode manufactures "nothing to fix" — the tidy, on-theme,
# investigation-ending answer.
#
# WHAT THIS DOES
# --------------
#   * uses `command grep` explicitly (GNU grep, not the shim)
#   * bounds scope to code paths, excluding the volatile trees that are 97% of
#     the payload and never contain call sites
#   * runs the search TWICE and refuses to emit a count unless both runs exit 0
#     AND produce byte-identical output
#   * prints the ENUMERATION, not just a number — a list can be checked
#   * uses PIPESTATUS, never $?, because in a pipeline $? is the LAST command:
#     `cmd | tail -6; echo "exit=$?"` reports tail's status, which is how the
#     original exit-code rule failed four hours after it was written
#
# Usage:
#   sweep.sh <pattern> [path ...]        default paths: cortextos src/scripts/templates
#   sweep.sh --all-files <pattern> [...] include non-code files (still excludes volatile trees)
#   sweep.sh --count-only <pattern> ...  print just the count (only if it is admissible)
#
# Exit: 0 stable result · 1 unstable or a run failed (count NOT admissible) · 2 usage

set -uo pipefail

EXCLUDES=(
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.next
  --exclude-dir=venv --exclude-dir=.venv --exclude-dir=site-packages
  --exclude-dir=memory --exclude-dir=logs --exclude-dir=state
  --exclude-dir=workspace --exclude-dir=handoffs --exclude-dir=.remember
  --exclude-dir=__pycache__ --exclude-dir=dist --exclude-dir=build
)
ALL_FILES=0
COUNT_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --all-files)  ALL_FILES=1; shift ;;
    --count-only) COUNT_ONLY=1; shift ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) echo "sweep.sh: unknown option $1" >&2; exit 2 ;;
    *)  break ;;
  esac
done

PATTERN="${1:-}"
[ -n "$PATTERN" ] || { echo "usage: sweep.sh [--all-files] [--count-only] <pattern> [path ...]" >&2; exit 2; }
shift
PATHS=("$@")
[ ${#PATHS[@]} -gt 0 ] || PATHS=(/home/claude-dev/cortextos/src /home/claude-dev/cortextos/scripts /home/claude-dev/cortextos/templates)

run_once() {
  local out="$1"
  if [ "$ALL_FILES" -eq 1 ]; then
    command grep -rl -E "$PATTERN" "${EXCLUDES[@]}" "${PATHS[@]}" > "$out" 2>/dev/null
  else
    command grep -rl -E "$PATTERN" "${EXCLUDES[@]}" \
      --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' \
      --include='*.py' --include='*.sh' --include='*.cs' --include='*.sql' \
      --include='*.json' --include='*.yaml' --include='*.yml' \
      "${PATHS[@]}" > "$out" 2>/dev/null
  fi
  # grep exits 1 on "no matches", which is a legitimate empty result, not a
  # failure. Only >1 is a real error.
  local rc=${PIPESTATUS[0]}
  [ "$rc" -le 1 ] || return "$rc"
  return 0
}

A=$(mktemp); B=$(mktemp)
trap 'rm -f "$A" "$B"' EXIT

run_once "$A"; RC_A=$?
run_once "$B"; RC_B=$?

if [ "$RC_A" -ne 0 ] || [ "$RC_B" -ne 0 ]; then
  echo "sweep: SEARCH FAILED (exit $RC_A / $RC_B). Count is NOT admissible." >&2
  exit 1
fi

if ! cmp -s "$A" "$B"; then
  echo "sweep: UNSTABLE — two consecutive runs of an identical query disagreed." >&2
  echo "  run 1: $(command grep -c . "$A") files" >&2
  echo "  run 2: $(command grep -c . "$B") files" >&2
  echo "  A count that is not reproducible is not a count. Investigate before quoting it." >&2
  exit 1
fi

N=$(command grep -c . "$A")
if [ "$COUNT_ONLY" -eq 1 ]; then
  echo "$N"
else
  sort "$A"
  echo "---"
  echo "sweep: $N file(s) — stable across 2 runs, GNU grep, code paths only."
  echo "       Pattern: $PATTERN"
  echo "       This is an ENUMERATION. Read it; do not just quote the number."
fi
exit 0
