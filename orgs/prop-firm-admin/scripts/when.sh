#!/usr/bin/env bash
# when.sh — answer "what time is it for Chris, and may I message him right now?"
#
# Why this exists: 2026-08-11, chief read the UTC shell clock (10:17) as Central
# and announced a brief "in ten minutes". Central was 5:17 AM. Sending would have
# put a decision request in Chris's Telegram at 5:26 AM, mid night-mode. A
# four-hour error, caught by luck rather than by process.
#
# The shell clock is UTC. Chris is America/Chicago. Every agent that reads `date`
# without a TZ and reasons about "morning" is one step from the same mistake.
#
# Usage:
#   bash when.sh              # human-readable
#   bash when.sh --quiet      # exit code only: 0 = day mode (ok to message), 1 = night mode
#   bash when.sh --until 10:00   # how long until that CT time
#
# Night mode is 02:00-10:00 CT: no proactive Telegram to Chris. Route via chief.

set -uo pipefail
ORG_TZ="${CTX_TIMEZONE:-America/Chicago}"
QUIET=0
UNTIL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --until) UNTIL="${2:-}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Night mode 02:00-10:00 local. Computed from the real clock, never from a stored
# timestamp — see feedback_absolute_times_only.
# Validate the zone EXISTS before trusting anything derived from it.
# GNU date does NOT error on an unknown TZ — it silently falls back to UTC. So a
# typo'd or unset zone yields a confident, wrong, UTC-based answer. That is the
# precise failure this script was written to catch (2026-08-11: UTC read as
# Central, four hours out), and the first version of this guard reproduced it:
# with TZ='Not/AZone' it reported DAY MODE at 5:19 AM CT.
if [ ! -f "/usr/share/zoneinfo/$ORG_TZ" ]; then
  echo "when.sh: TIMEZONE '$ORG_TZ' DOES NOT EXIST (no /usr/share/zoneinfo/$ORG_TZ)." >&2
  echo "  GNU date would silently answer in UTC. Failing closed: treat as NIGHT MODE," >&2
  echo "  do not send, route via chief. Fix CTX_TIMEZONE." >&2
  exit 1
fi

HOUR=$(TZ="$ORG_TZ" date +%-H 2>/dev/null)

# Fail CLOSED. If we cannot determine the hour — bad TZ, missing zoneinfo, date
# unavailable — treat it as night mode and block the send. A check that cannot
# answer must never answer "go ahead": an unparseable HOUR previously fell
# through `[ "" -ge 2 ]` (which errors, exit 2) into the else branch and reported
# DAY MODE, i.e. the broken check authorised the send. That is the exact
# inversion this script exists to prevent.
if ! printf '%s' "$HOUR" | grep -qE '^[0-9]{1,2}$' || [ "$HOUR" -gt 23 ]; then
  echo "when.sh: CANNOT DETERMINE LOCAL TIME (TZ='$ORG_TZ', date returned '${HOUR}')." >&2
  echo "  Failing closed: treating as NIGHT MODE. Do not send; route via chief." >&2
  exit 1
fi

# Night window is ORG POLICY, not a universal. 02:00-10:00 is prop-firm-admin's
# (Chris's) and is the default only because it is the one that has been ruled on.
# Any org can override without waiting for a ruling:
#   CTX_NIGHT_START=0 CTX_NIGHT_END=6   (or set them in the org env)
# Set both equal to disable night mode entirely for an org that has no quiet hours.
NIGHT_START="${CTX_NIGHT_START:-2}"
NIGHT_END="${CTX_NIGHT_END:-10}"

for v in "$NIGHT_START" "$NIGHT_END"; do
  if ! printf '%s' "$v" | grep -qE '^([0-9]|1[0-9]|2[0-3])$'; then
    echo "when.sh: invalid night window ($NIGHT_START-$NIGHT_END); hours must be 0-23." >&2
    echo "  Failing closed: treating as NIGHT MODE. Do not send." >&2
    exit 1
  fi
done

if [ "$NIGHT_START" -eq "$NIGHT_END" ]; then
  NIGHT=0                                     # explicitly disabled: no quiet hours
elif [ "$NIGHT_START" -lt "$NIGHT_END" ]; then
  if [ "$HOUR" -ge "$NIGHT_START" ] && [ "$HOUR" -lt "$NIGHT_END" ]; then NIGHT=1; else NIGHT=0; fi
else                                          # window wraps midnight, e.g. 22-06
  if [ "$HOUR" -ge "$NIGHT_START" ] || [ "$HOUR" -lt "$NIGHT_END" ]; then NIGHT=1; else NIGHT=0; fi
fi

if [ "$QUIET" -eq 1 ]; then exit "$NIGHT"; fi

ZLABEL=$(TZ="$ORG_TZ" date +%Z)
echo "UTC now   $(date -u +'%Y-%m-%d %H:%M')"
printf '%-9s %s\n' "$ZLABEL now" "$(TZ="$ORG_TZ" date +'%A %B %-d, %-I:%M %p %Z')  [$ORG_TZ]"

if [ "$NIGHT" -eq 1 ]; then
  echo "MODE      NIGHT ($(printf %02d "$NIGHT_START"):00-$(printf %02d "$NIGHT_END"):00 $ZLABEL) — do NOT send proactive Telegram to the user. Route via your orchestrator."
else
  echo "MODE      DAY ($ZLABEL) — direct Telegram to the user is allowed."
fi

if [ -n "$UNTIL" ]; then
  TZ="$ORG_TZ" python3 - "$UNTIL" "$ORG_TZ" <<'PYEOF'
import sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
target, tzname = sys.argv[1], sys.argv[2]
tz = ZoneInfo(tzname)
now = datetime.now(tz)
h, _, m = target.partition(":")
t = now.replace(hour=int(h), minute=int(m or 0), second=0, microsecond=0)
if t < now:
    t += timedelta(days=1)
d = t - now
print(f"UNTIL     {target} local is in {d.seconds//3600}h {(d.seconds%3600)//60}m "
      f"(= {t.astimezone(ZoneInfo('UTC')).strftime('%H:%M UTC')})")
PYEOF
fi
