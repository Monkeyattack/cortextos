#!/usr/bin/env bash
# eas-build-watch.sh — report on a specific EAS build, fail-closed.
#
# Built 2026-08-04 for nlp-training build e39306cc (Supabase env fix, Chris waiting).
# Same shape as h137-cluster-exit-watch.sh: it reports a real state or an explicit
# ERROR, and NEVER reports "not finished" when it simply could not find out.
#
# usage: eas-build-watch.sh <build-id> [app-dir]
# exit 0 = state determined (may be in progress)
# exit 2 = could NOT determine (treat as a problem, never as "still building")
set -uo pipefail

BUILD_ID="${1:-}"
APP_DIR="${2:-/home/claude-dev/repos/nlp-app/apps/mobile}"
[ -z "$BUILD_ID" ] && { echo "[eas-watch] usage: $0 <build-id> [app-dir]"; exit 2; }

cd "$APP_DIR" 2>/dev/null || { echo "[eas-watch] ERROR: cannot cd to $APP_DIR"; exit 2; }

raw=$(timeout 150 npx --no-install eas build:list --platform ios --limit 5 --non-interactive 2>&1)
rc=$?
if [ $rc -ne 0 ] && ! printf '%s' "$raw" | grep -q "$BUILD_ID"; then
  echo "[eas-watch] ERROR: eas build:list failed (rc=$rc) — build state UNKNOWN, not assumed"
  exit 2
fi

# Pull the block for our build id: the ID line plus the following lines up to the next ID.
block=$(printf '%s\n' "$raw" | awk -v id="$BUILD_ID" '
  $1=="ID" && $2==id {grab=1; print; next}
  grab && $1=="ID" {grab=0}
  grab {print}
')

if [ -z "$block" ]; then
  echo "[eas-watch] ERROR: build $BUILD_ID not present in the last 5 iOS builds — UNKNOWN, not assumed"
  exit 2
fi

status=$(printf '%s\n' "$block" | awk '$1=="Status"{ $1=""; sub(/^ +/,""); print; exit }')
url=$(printf '%s\n' "$block" | grep -oE 'https://expo\.dev/[^ ]+' | head -1)
[ -z "$status" ] && { echo "[eas-watch] ERROR: could not parse Status for $BUILD_ID — UNKNOWN"; exit 2; }

echo "[eas-watch] $(date -u +%Y-%m-%dT%H:%M:%SZ)  build=$BUILD_ID  status=$status"
[ -n "$url" ] && echo "  $url"

case "$status" in
  *finished*)  echo "[eas-watch] DONE — build finished. Chris must INSTALL THE NEW BUILD; reopening the old app cannot pick up EXPO_PUBLIC_* values (compiled in at build time)." ;;
  *error*|*fail*|*cancel*) echo "[eas-watch] FAILED — report the ACTUAL error to Chris, not a summary. Logs at the URL above." ;;
  *) echo "[eas-watch] still building — no action." ;;
esac
exit 0
