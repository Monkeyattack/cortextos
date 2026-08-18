#!/usr/bin/env bash
# deploy-static-site.sh — stage-and-swap deploy for a static/web build, fail-closed.
#
# WHY THIS IS A SCRIPT AND NOT A CHECKLIST
#   DEPLOY-RUNBOOK.md documents nine traps. Prose does not stop any of them: on 2026-08-05
#   the runbook's OWN stage-and-swap snippet carried the mv-into-existing-dir bug for hours,
#   surviving the author writing it, the author using it, and a reviewer reading it.
#   Per the fleet rule (guards ship as fail-closed scripts, false-positive rate is a
#   first-class defect), the checks live here where they cannot be skipped by a tired
#   operator at 05:00.
#
# THE FOUR FAILURES IT MAKES IMPOSSIBLE, all observed on real deploys:
#   1. mv-into-existing-dir. `mv live .old` NESTS when .old exists, leaving .old pointing at
#      the version BEFORE last. Rollback then serves two-versions-back and exits 0 — a
#      rollback that LIES. First deploy of a site hides it; the second arms it.
#   2. umask 0077. This account creates 700/600, nginx runs as www-data, everything 403s.
#      Perms are fixed while STAGED, so the site is never live-but-unreadable.
#   3. Verifying the wrong file. For Godot, index.wasm is the ENGINE and index.pck is the
#      GAME — two different content builds had byte-identical wasm. Hashing the unchanged
#      file confirms "a successful deploy of nothing". --verify-file names what must change.
#   4. curl | md5sum on a binary. Piping corrupts it and yields a confident wrong hash.
#      Always --output to a file first.
#
# FAIL-CLOSED: exit 2 means UNDETERMINED — could not verify. It NEVER reports success when
# it could not look. A deploy script that says "done" because a check failed to run is the
# same defect class as an alert that says all-clear because it crashed.
#
# usage: deploy-static-site.sh --src DIR --live DIR --url URL [--verify-file NAME] [--keep-old]
# exit 0 = deployed AND verified live
# exit 1 = deploy performed but verification FAILED (site may be broken — read the output)
# exit 2 = UNDETERMINED / refused to proceed (nothing swapped unless stated)
set -uo pipefail

SRC=""; LIVE=""; URL=""; VERIFY_FILE=""; KEEP_OLD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="${2:-}"; shift 2 ;;
    --live) LIVE="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --verify-file) VERIFY_FILE="${2:-}"; shift 2 ;;
    --keep-old) KEEP_OLD=1; shift ;;
    *) echo "[deploy] UNDETERMINED: unknown arg $1"; exit 2 ;;
  esac
done

for v in SRC LIVE URL; do
  [ -z "${!v}" ] && { echo "[deploy] UNDETERMINED: --${v,,} is required"; exit 2; }
done
[ -d "$SRC" ] || { echo "[deploy] UNDETERMINED: source $SRC is not a directory"; exit 2; }
[ -n "$(ls -A "$SRC" 2>/dev/null)" ] || { echo "[deploy] UNDETERMINED: source $SRC is EMPTY — refusing to deploy nothing"; exit 2; }

BASE=$(dirname "$LIVE")
NEW="$BASE/.deploy-new.$$"
OLD="$BASE/$(basename "$LIVE").old"

# Trap 3: the changed-file check. Capture the SOURCE hash before anything moves.
src_hash=""
if [ -n "$VERIFY_FILE" ]; then
  if [ ! -f "$SRC/$VERIFY_FILE" ]; then
    echo "[deploy] UNDETERMINED: --verify-file '$VERIFY_FILE' not present in source — cannot verify, refusing"
    exit 2
  fi
  src_hash=$(md5sum "$SRC/$VERIFY_FILE" | cut -d' ' -f1)
  echo "[deploy] verify-file: $VERIFY_FILE  src_md5=$src_hash"
fi

echo "[deploy] staging $SRC -> $NEW"
rm -rf "$NEW" || { echo "[deploy] UNDETERMINED: could not clear stage dir $NEW"; exit 2; }
mkdir -p "$NEW" && cp -r "$SRC"/. "$NEW"/ || { echo "[deploy] UNDETERMINED: copy to stage failed — nothing swapped"; rm -rf "$NEW"; exit 2; }

# Trap 2: fix perms WHILE STAGED, before anything is reachable.
chmod -R a+rX "$NEW" || { echo "[deploy] UNDETERMINED: chmod on stage failed — nothing swapped"; rm -rf "$NEW"; exit 2; }

# Trap 1: .old MUST NOT EXIST before the mv, or the mv nests instead of renaming.
if [ -e "$OLD" ]; then
  if [ "$KEEP_OLD" -eq 1 ]; then
    echo "[deploy] REFUSING: $OLD exists and --keep-old was given."
    echo "[deploy] mv would NEST the live dir inside it, leaving $OLD pointing at the version"
    echo "[deploy] BEFORE last — a later rollback would silently serve two-versions-back."
    echo "[deploy] Move or rename $OLD yourself, then re-run. Nothing was swapped."
    rm -rf "$NEW"; exit 2
  fi
  echo "[deploy] removing stale $OLD (would otherwise nest — see runbook sec 6)"
  rm -rf "$OLD" || { echo "[deploy] UNDETERMINED: could not remove $OLD — nothing swapped"; rm -rf "$NEW"; exit 2; }
fi

if [ -e "$LIVE" ]; then
  mv "$LIVE" "$OLD" || { echo "[deploy] UNDETERMINED: could not move live aside — nothing swapped"; rm -rf "$NEW"; exit 2; }
fi
mv "$NEW" "$LIVE" || {
  echo "[deploy] FAILED mid-swap — attempting rollback"
  [ -e "$OLD" ] && mv "$OLD" "$LIVE" && echo "[deploy] rolled back to previous build"
  exit 2
}
echo "[deploy] swapped. previous build retained at $OLD"

# Trap 1 again, asserted: a correct swap leaves NO nested copy inside .old.
if [ -e "$OLD/$(basename "$LIVE")" ]; then
  echo "[deploy] UNDETERMINED: $OLD contains a nested $(basename "$LIVE") — the mv nested."
  echo "[deploy] The rollback target is WRONG. Do not trust $OLD."
  exit 2
fi

echo "[deploy] verifying $URL"
code=$(curl -s -o /dev/null -m 30 -w '%{http_code}' "$URL" 2>/dev/null)
if [ -z "$code" ] || [ "$code" = "000" ]; then
  echo "[deploy] UNDETERMINED: no HTTP response from $URL — deploy happened, liveness UNKNOWN"
  exit 2
fi
echo "[deploy] HTTP $code"
[ "$code" = "200" ] || { echo "[deploy] FAILED: $URL returned $code (403 => check perms above $LIVE too, not just inside it)"; exit 1; }

# Trap 3 + 4: hash the file that CHANGED, via --output (never a pipe).
if [ -n "$VERIFY_FILE" ]; then
  tmp=$(mktemp)
  base_url="${URL%/}"
  if ! curl -s -m 60 --output "$tmp" "$base_url/$VERIFY_FILE" 2>/dev/null; then
    echo "[deploy] UNDETERMINED: could not fetch $VERIFY_FILE — content NOT verified"; rm -f "$tmp"; exit 2
  fi
  live_hash=$(md5sum "$tmp" | cut -d' ' -f1); rm -f "$tmp"
  if [ "$live_hash" != "$src_hash" ]; then
    echo "[deploy] FAILED: $VERIFY_FILE live md5=$live_hash != src md5=$src_hash"
    echo "[deploy] Served content does not match what was built. Check CDN cache before re-deploying."
    exit 1
  fi
  echo "[deploy] content verified: $VERIFY_FILE md5=$live_hash matches source"
fi

echo "[deploy] OK — deployed and verified."
echo "[deploy] NOTE: this proves RENDER-reachability only. FEEL (sequencing, input-locking) needs"
echo "[deploy] a driven browser, and AUDIBLE needs a human. See DEPLOY-RUNBOOK.md sec 1."
echo "[deploy] Rollback: rm -rf '$LIVE' && mv '$OLD' '$LIVE'"
exit 0
