#!/usr/bin/env bash
# repo-safe-push.sh <repo-dir> <github-url>
# Mandatory pre-push checklist (fleet standard, 2026-08-03). Fails closed.
#  1. FULL-HISTORY secret scan (not just working tree — a key committed in March and
#     deleted in April still ships in history and makes a private repo unsafe)
#  2. tracked .env must be *.example only
#  3. no tracked file over GitHub's 100M hard limit
#  4. target repo must be PRIVATE
#  5. post-push: remote HEAD == local HEAD, repo non-empty
set -uo pipefail

DIR="${1:?usage: repo-safe-push.sh <repo-dir> <github-url>}"
URL="${2:?usage: repo-safe-push.sh <repo-dir> <github-url>}"
SLUG=$(sed -E 's#.*github.com[:/]##; s#\.git$##' <<<"$URL")
cd "$DIR" || exit 1
fail() { echo "  ✗ BLOCKED: $*"; exit 1; }

echo "=== $DIR -> $SLUG ==="

# 1. full-history secret scan
# Leading (?<![A-Za-z0-9-]) is load-bearing: without it "risk-management-guide-2025"
# inside a URL matches the sk- branch and blocks a clean repo (hit on polymarket).
HITS=$(git log --all -p --no-color 2>/dev/null | grep -aoP \
  '(?<![A-Za-z0-9-])(sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' \
  | sort -u)
[[ -n "$HITS" ]] && { echo "$HITS" | head -5; fail "secrets found in history"; }
echo "  ✓ history scan clean ($(git rev-list --all --count) commits)"

# 2. tracked .env must be examples only
BADENV=$(git ls-files | grep -iE '\.env' | grep -viE '\.example$|\.sample$' || true)
[[ -n "$BADENV" ]] && { echo "$BADENV"; fail "non-example .env tracked"; }
echo "  ✓ no real .env tracked"

# 3. file size ceiling
BIG=$(git ls-files -z | xargs -0 du -m 2>/dev/null | awk '$1>99{print $1"M "$2}')
[[ -n "$BIG" ]] && { echo "$BIG"; fail "file(s) over GitHub 100M limit"; }
echo "  ✓ no file over 100M"

# 4. target must be private
VIS=$(gh repo view "$SLUG" --json visibility -q .visibility 2>/dev/null)
[[ "$VIS" == "PRIVATE" ]] || fail "target repo is '$VIS', refusing to push"
echo "  ✓ target is PRIVATE"

# 4b. browser-create detection. GitHub's web UI can seed a repo with a lone "Initial
# commit" README, which has no shared history with a local repo and makes the push
# non-fast-forward. Detect ONLY that exact shape and tell the operator what to run.
# Deliberately does NOT auto-merge: `-X ours` discards the remote side on conflict, which
# is safe for a stub README and unsafe for anything else. If the remote has more than one
# commit, or touches anything but README, we keep blocking hard and a human looks at it.
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$URL"
git fetch -q origin 2>/dev/null || true
CURBR=$(git rev-parse --abbrev-ref HEAD)
# Prefer the branch ref we are actually pushing. `ls-remote origin HEAD` returns empty on
# some remotes (bare repos with no symbolic HEAD) — caught by a synthetic test, where the
# empty value silently skipped this whole block and let git fail with a raw error instead.
RHEAD=$(git ls-remote origin "refs/heads/$CURBR" | cut -f1)
[[ -z "$RHEAD" ]] && RHEAD=$(git ls-remote origin HEAD | cut -f1)
if [[ -n "$RHEAD" ]] && ! git merge-base --is-ancestor "$RHEAD" HEAD 2>/dev/null; then
  git fetch -q origin "$RHEAD" 2>/dev/null || true
  RCOUNT=$(git rev-list --count "$RHEAD" 2>/dev/null || echo 99)
  RTOTAL=$(git show --name-only --format="" "$RHEAD" 2>/dev/null | grep -c . || echo 99)
  # match on basename so paths and --stat padding cannot break it
  RFILES=$(git show --name-only --format="" "$RHEAD" 2>/dev/null \
             | xargs -r -n1 basename 2>/dev/null \
             | grep -ciE '^(README(\..*)?|\.gitignore|LICENSE(\..*)?)$' || echo 0)
  if [[ "$RCOUNT" == "1" && "$RTOTAL" -le 3 && "$RFILES" -ge 1 ]]; then
    echo "  ! remote has a lone browser-create stub commit (${RHEAD:0:7}, $RTOTAL file(s))"
    echo "    run, then re-run this script:"
    echo "      git merge --allow-unrelated-histories -X ours $RHEAD -m 'chore: absorb GitHub browser-create stub'"
    echo "      git diff --stat HEAD@{1} HEAD   # must be empty — confirm nothing local was dropped"
    fail "unrelated remote history (browser-create stub) — resolve as above"
  fi
  fail "remote HEAD $RHEAD is not an ancestor of local and is NOT a lone stub — human review"
fi

# push
git push -q -u origin --all 2>&1 | tail -3

# 5. verify remote matches local
BR=$(git rev-parse --abbrev-ref HEAD)
LOCAL=$(git rev-parse "$BR")
REMOTE=$(git ls-remote origin "refs/heads/$BR" | cut -f1)
[[ "$LOCAL" == "$REMOTE" ]] || fail "remote HEAD ($REMOTE) != local ($LOCAL)"
echo "  ✓ PUSHED + VERIFIED  $BR@${LOCAL:0:7} == remote"
