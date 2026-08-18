#!/usr/bin/env bash
# transcript-size-alarm.sh — fleet-wide session-transcript size check.
#
# WHY THIS EXISTS
#   A 15.7MB session JSONL was the ROOT CAUSE of 3+ hours of heartbeat staleness
#   on render-monitor. The fix at the time was a hard stop plus a JSONL delete.
#   On 2026-08-04 an enumeration found FOURTEEN transcripts above that size across
#   ELEVEN agents in BOTH orgs — 0.58GB, ~27% of all transcript bytes. The largest
#   was fable-reviewer at 137.9MB, 8.8x the size that already caused an outage.
#   Nothing was checking for this. Not the daemon, not any agent, not any cron.
#
# *** THE THRESHOLD IS PROVISIONAL — READ THIS BEFORE ARMING ***
#   15.7MB is the ONE CONFIRMED OUTAGE, not a measured safe ceiling. Nobody has
#   established the size at which degradation begins; we only know one file that
#   was fatal. So 15.7MB is an upper bound on "known bad", NOT a tested limit, and
#   the alarm threshold deliberately sits BELOW it. Setting the alarm AT 15.7MB
#   would only warn you once you had already reached a size known to kill an agent.
#   The real threshold is a Chris decision. If you are arming this, that decision
#   should have been made — do not inherit this default silently.
#
# *** SIZE ALONE IS NOT RISK — RECENCY IS THE DISCRIMINATOR (v2, 2026-08-04) ***
#   v1 of this script measured size only. Its first real run flagged 19 files led by
#   fable-reviewer 137.9MB, render-monitor 79.4MB, analyst 75.5MB — and ALL THREE were
#   DORMANT: last written 1 day, 3 days and 18 DAYS earlier. Nothing reads or appends to
#   them, so they cannot stall anything. The live sessions were 1.3MB, 2.5MB and 1.7MB.
#   A big dead transcript is a disk-space question, not an outage risk, and alarming on it
#   forever after remediation is alert fatigue by construction — the exact defect this
#   project exists to remove. fable-reviewer had ALREADY self-remediated by restarting;
#   the file stopped growing, and v1 would have kept escalating it indefinitely.
#   So: flag only when a file is BOTH over threshold AND written within RECENT_HOURS.
#
# WHY SIZE AND NOT TOKEN COUNT
#   Token volume cannot distinguish "many small sessions" from "one enormous one".
#   File size can. The fleet-wide picture only appeared when the size instrument was
#   applied across every project dir; token totals alone had hidden it for months.
#
# FAIL-CLOSED, same rule as every check in the monitoring SOW:
#   if this cannot read the transcript tree it reports UNDETERMINED and exits 2.
#   It NEVER reports "no files over threshold" when it could not look. An alarm that
#   is silent because it is broken is indistinguishable from an alarm that is silent
#   because things are fine — and that ambiguity is the whole failure class this
#   project exists to remove.
#
# usage: transcript-size-alarm.sh [--threshold-mb N] [--recent-hours N] [--quiet]
# exit 0 = checked, nothing over threshold
# exit 1 = checked, one or more files OVER threshold (real alarm)
# exit 2 = COULD NOT DETERMINE (treat as a problem, never as "all clear")
set -uo pipefail

ROOT="${HOME}/.claude/projects"
KNOWN_FATAL_MB=15.7          # the one confirmed outage. NOT a safe ceiling.
THRESHOLD_MB=10              # provisional, deliberately BELOW the known-fatal size
RECENT_HOURS=7               # 7h > 6h alarm cadence — consecutive runs overlap, no blind band
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold-mb) THRESHOLD_MB="${2:-}"; shift 2 ;;
    --recent-hours) RECENT_HOURS="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "[transcript-alarm] unknown arg: $1"; exit 2 ;;
  esac
done

case "$THRESHOLD_MB" in
  ''|*[!0-9.]*) echo "[transcript-alarm] UNDETERMINED: --threshold-mb must be numeric, got '${THRESHOLD_MB}'"; exit 2 ;;
esac

if [ ! -d "$ROOT" ]; then
  echo "[transcript-alarm] UNDETERMINED: transcript root $ROOT is not a directory — cannot look, NOT reporting all-clear"
  exit 2
fi

listing=$(find "$ROOT" -type f -name '*.jsonl' -mmin "-$((RECENT_HOURS*60))" -printf '%s\t%T@\t%p\n' 2>/dev/null)
rc=$?   # MUST be captured here: it is the RECENT find's status. Capturing it after the
        # all_count pipeline below would read `wc -l`'s status instead, which practically
        # never fails, silently turning the instrument-failure check into dead code.
# NOTE: `listing` is RECENT files only, so an empty listing cannot itself signal
# instrument failure — a genuinely quiet fleet has none. The all-files probe below is
# what distinguishes "nothing happening" from "cannot see anything".
all_count=$(find "$ROOT" -type f -name '*.jsonl' 2>/dev/null | wc -l)
if [ $rc -ne 0 ] && [ -z "$listing" ]; then
  echo "[transcript-alarm] UNDETERMINED: find failed (rc=$rc) over $ROOT — NOT reporting all-clear"
  exit 2
fi
if [ "$all_count" -eq 0 ]; then
  # Zero .jsonl files ANYWHERE is implausible on a live box: instrument failure, not all-clear.
  echo "[transcript-alarm] UNDETERMINED: zero transcripts found under $ROOT at all — implausible, treating as instrument failure not all-clear"
  exit 2
fi
if [ -z "$listing" ]; then
  # Files exist but none written recently. That is a genuinely quiet fleet, NOT a failure.
  echo "[transcript-alarm] $(date -u +%Y-%m-%dT%H:%M:%SZ)  scanned=${all_count} recent=0 (${RECENT_HOURS}h)  OK — no active transcripts in window."
  exit 0
fi

# ── Superseded-transcript filter ──────────────────────────────────────────────
# A time window cannot tell a LIVE transcript from a DEAD one. A session boundary
# is far shorter than RECENT_HOURS, so every restart leaves a large corpse that
# still reads as "written recently" for hours afterwards. v2 was built to stop
# flagging dormant files and still did, just with a 7h horizon instead of an
# unlimited one.
#
# 2026-08-11: flagged render-monitor 9cd063ee at 10.5MB. That file had not been
# written for 5.0h; the agent was live on a fresh 1.2MB transcript and its
# heartbeat was 3 minutes old. False positive.
#
# Exact test, no threshold to tune: a transcript is live only if it is the NEWEST
# .jsonl in its own project directory. A larger, older file sitting beside a newer
# one for the same agent is abandoned by definition.
#
# Suppressed files are COUNTED and reported, never silently dropped — an
# instrument that hides its own filtering is how the previous version looked
# correct while being wrong.
filtered=$(printf '%s\n' "$listing" | python3 -c '
import sys, os
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line: continue
    parts = line.split("\t", 2)
    if len(parts) != 3: continue
    size, mtime, path = parts
    rows.append((int(size), float(mtime), path))
newest = {}
for _, mt, path in rows:
    d = os.path.dirname(path)
    if mt > newest.get(d, -1.0): newest[d] = mt
kept, dropped = [], 0
for size, mt, path in rows:
    if mt >= newest[os.path.dirname(path)]:
        kept.append(f"{size}\t{path}")
    else:
        dropped += 1
sys.stderr.write(str(dropped))
print("\n".join(kept))
' 2>/tmp/.tsa_dropped)
superseded=$(cat /tmp/.tsa_dropped 2>/dev/null || echo 0)
rm -f /tmp/.tsa_dropped
listing="$filtered"

over=$(printf '%s\n' "$listing" | awk -v t="$THRESHOLD_MB" -v f="$KNOWN_FATAL_MB" '
  { mb = $1 / 1048576
    if (mb >= t) {
      path=$2; for (i=3;i<=NF;i++) path=path" "$i
      n=split(path,parts,"/"); agent="?"
      for (i=1;i<=n;i++) if (parts[i] ~ /^-home-claude-dev/) { agent=parts[i]; break }
      sub(/^.*agents-/,"",agent)
      printf "%8.1fMB  %5.1fx-fatal  %-22s %s\n", mb, mb/f, agent, parts[n]
    }
  }' | sort -rn)

recent_total=$(printf '%s\n' "$listing" | wc -l)
count=$(printf '%s' "$over" | grep -c . || true)

echo "[transcript-alarm] $(date -u +%Y-%m-%dT%H:%M:%SZ)  scanned=${all_count}  live=${recent_total} (newest-per-agent, ${superseded:-0} superseded suppressed)  threshold=${THRESHOLD_MB}MB  over=${count}"
echo "[transcript-alarm] NOTE: ${KNOWN_FATAL_MB}MB is the ONE CONFIRMED OUTAGE, not a tested safe ceiling. Threshold is provisional."

if [ "$count" -gt 0 ]; then
  [ "$QUIET" -eq 0 ] && printf '%s\n' "$over"
  echo "[transcript-alarm] ALARM: ${count} LIVE transcript(s) at or over ${THRESHOLD_MB}MB and written within ${RECENT_HOURS}h AND newest for their agent."
  echo "[transcript-alarm] Remediation is a session restart at a clean boundary, not a file delete on a live agent."
  echo "[transcript-alarm] PRIORITISE GATE/ORCHESTRATOR AGENTS: a stalled monitor goes quiet and gets noticed; a stalled GATE blocks merges while looking like ordinary review latency."
  exit 1
fi

echo "[transcript-alarm] OK — no ACTIVE transcript at or over threshold."
exit 0
