#!/usr/bin/env bash
# orb-status-staleness.sh — assert the forward-test pipeline is actually PRODUCING.
#
# WHY THIS EXISTS: devops forward-test-refresh aborted on all 35 fires from 2026-06-22 to
# 2026-08-04 and nobody noticed. The guard failed LOUDLY every single time. Loud was not
# enough — a duplicate cron kept orb_status looking fresh, so the downstream artifact
# appeared healthy and nobody read the error.
#
# So this asserts the ABSENCE of a fresh write, not the presence of an error. Errors were
# already visible and did not help.
#
# Usage: orb-status-staleness.sh [--max-age-hours N] [--quiet]
# Exit:  0 = fresh   1 = STALE (alert)   2 = could not check (also an alert — see below)
set -uo pipefail

MAX_AGE_H=26          # daily producer + schedule jitter; >26h means a run was genuinely missed
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-age-hours) MAX_AGE_H="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Only assert on instruments something is actually SCHEDULED to produce. orb_status also
# carries MES, which no current cron writes (last write 2026-07-08) — asserting on it would
# emit a permanent false alarm, and a check that always cries wolf gets muted, which is how
# we got here.
EXPECTED=(MCL MNQ)

ENVF=/home/claude-dev/repos/orbfutures/.env
[[ -f "$ENVF" ]] || { echo "STALENESS-CHECK ERROR: $ENVF missing — cannot reach the DB"; exit 2; }
DBURL=$(grep -m1 '^DATABASE_URL=' "$ENVF" | cut -d= -f2- | tr -d '"')
[[ -n "$DBURL" ]] || { echo "STALENESS-CHECK ERROR: DATABASE_URL unset in $ENVF"; exit 2; }

IN_LIST=$(printf "'%s'," "${EXPECTED[@]}"); IN_LIST=${IN_LIST%,}
ROWS=$(psql "$DBURL" -tA -F'|' -c "
  SELECT instrument,
         ROUND(EXTRACT(EPOCH FROM (NOW() - updated_at))/3600.0, 1),
         updated_at
  FROM orb_status WHERE instrument IN ($IN_LIST);" 2>&1)

if [[ $? -ne 0 || -z "$ROWS" ]]; then
  # Cannot check is NOT the same as fresh. Treat it as an alert — silently passing when the
  # check itself is broken is the exact failure mode this script exists to catch.
  echo "STALENESS-CHECK ERROR: query failed or returned nothing — treating as ALERT"
  echo "$ROWS" | head -3
  exit 2
fi

STALE=(); OK=(); SEEN=()
while IFS='|' read -r inst age ts; do
  [[ -z "$inst" ]] && continue
  SEEN+=("$inst")
  if awk -v a="$age" -v m="$MAX_AGE_H" 'BEGIN{exit !(a>m)}'; then
    STALE+=("$inst ${age}h old (last write $ts)")
  else
    OK+=("$inst ${age}h")
  fi
done <<< "$ROWS"

# An instrument missing from orb_status entirely is stale in the worst way — never written.
for want in "${EXPECTED[@]}"; do
  found=0; for s in "${SEEN[@]}"; do [[ "$s" == "$want" ]] && found=1; done
  [[ $found -eq 0 ]] && STALE+=("$want ABSENT from orb_status — never written")
done

if [[ ${#STALE[@]} -gt 0 ]]; then
  echo "ORB_STATUS STALE (threshold ${MAX_AGE_H}h) — the forward-test pipeline is not producing:"
  printf '  %s\n' "${STALE[@]}"
  [[ ${#OK[@]} -gt 0 ]] && printf '  (fresh: %s)\n' "${OK[*]}"
  echo "Check: devops forward-test-refresh (weekday 02:00 CT) and analyst forward-test-nightly (03:00 CT)."
  echo "Most likely cause: the run aborted. It will have said so loudly and nobody read it."
  exit 1
fi

[[ $QUIET -eq 0 ]] && echo "orb_status fresh: ${OK[*]} (threshold ${MAX_AGE_H}h)"
exit 0
