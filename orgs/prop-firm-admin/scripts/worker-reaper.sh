#!/usr/bin/env bash
# worker-reaper.sh — terminate spawn-worker sessions that are RELEASED but still alive.
#
# WHY
# ---
# 2026-08-11: fable-reviewer found 5 finished workers holding live sessions 8-13h
# after release, ~2GB. Later the same day, worker trader-room-c52nis was still
# running 5.8 HOURS after sending its own "c52nis DONE" message. A released
# worker costs memory, CPU and tokens while doing nothing.
#
# WHAT MAKES THIS HARD
# --------------------
# Nearly every instrument here lies about worker state:
#   * list-workers / crash alerts / status  -> unreliable, do not consult
#   * enabled-agents.json                   -> registry view, disagrees with PIDs
#   * logs/<worker>/outbound-messages.jsonl -> this is the TELEGRAM log
#     (src/telegram/logging.ts:55). Worker DONE messages are NOT here; they are
#     bus messages and land in processed|inbox|inflight/<parent>/*.json.
#     Reading the wrong file makes the DONE branch silently never fire.
#   * process cwd                           -> workspaces/ is shared and often
#     EMPTY; it cannot identify which worker a PID is.
#
# WHAT IS TRUSTWORTHY
# -------------------
#   * the PID itself, and the process CMDLINE — the worker name and PM task id
#     are in the spawn prompt, which is a hard PID->worker link
#   * a bus message from=<worker> containing DONE — the worker declaring itself
#     finished, not a registry claiming it on its behalf
#
# NO RESULT CAPS ANYWHERE. A `head -N` on a match list is how "no DONE for
# c52nis" was reported about a message that existed: 41 matches, 10 printed,
# absent-from-the-shown read as absent-from-the-set. Counts and decisions come
# from the full set; truncation is for display only.
#
# Usage:
#   worker-reaper.sh              REPORT ONLY (default — never kills)
#   worker-reaper.sh --kill       terminate confirmed-released workers
#   worker-reaper.sh --min-age N  minimum minutes since release (default 30)
#
# Exit: 0 always in report mode. 0 in --kill mode even if nothing was killed.

set -uo pipefail

MIN_AGE_MIN=30
KILL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --kill) KILL=1; shift ;;
    --min-age) MIN_AGE_MIN="${2:-30}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "worker-reaper: unknown arg $1" >&2; exit 2 ;;
  esac
done

LOG=/home/claude-dev/.cortextos/default/logs/devops/worker-reaper.jsonl
mkdir -p "$(dirname "$LOG")" 2>/dev/null

KILL="$KILL" MIN_AGE_MIN="$MIN_AGE_MIN" LOG="$LOG" python3 - <<'PYEOF'
import os, re, json, glob, subprocess, datetime, signal, sys

KILL      = os.environ.get('KILL') == '1'
MIN_AGE   = int(os.environ.get('MIN_AGE_MIN', '30'))
LOGPATH   = os.environ['LOG']
ROOT      = '/home/claude-dev/.cortextos/default'
now       = datetime.datetime.now(datetime.timezone.utc)

def log(ev):
    ev['ts'] = now.strftime('%Y-%m-%dT%H:%M:%SZ')
    with open(LOGPATH, 'a') as f:
        f.write(json.dumps(ev) + '\n')

# START LINE — written BEFORE any work, and it is the point of the whole thing.
#
# The summary line is written only after the scan completes. So a run that was
# killed mid-scan used to leave NOTHING in this log, and a missing line is
# indistinguishable from a quiet all-clear to anyone reading it. On 2026-08-12
# a run was killed at the five-minute mark and the log simply went silent after
# 19:15Z — the sweep had not run, and nothing said so.
#
# With this line, a killed run leaves a `start` with no matching `sweep` after
# it. That is a visible, greppable defect instead of an absence. A hygiene
# monitor that fails silent is worse than one that fails loud, because silence
# is what it emits when everything is fine.
log(dict(event='start', mode='KILL' if KILL else 'REPORT-ONLY', min_age_min=MIN_AGE))

# ── 1. Live claude processes, with cmdline (the identity source) ─────────────
procs = []
out = subprocess.run(['ps','-eo','pid,ppid,etimes,rss,cmd','--no-headers'],
                     capture_output=True, text=True).stdout
for line in out.splitlines():
    f = line.split(None, 4)
    if len(f) < 5:
        continue
    pid, ppid, et, rss, cmd = f
    if '/claude ' not in cmd and not cmd.strip().startswith('claude'):
        continue
    try:
        full = open(f'/proc/{pid}/cmdline','rb').read().replace(b'\0', b' ').decode('utf-8','replace')
    except Exception:
        full = cmd
    procs.append(dict(pid=pid, ppid=ppid, etimes=int(et), rss_mb=int(rss)//1024, cmdline=full))

# ── 2. Every DONE message on the bus that could possibly matter. ────────────
#
# NOT A CAP. The "NO CAP" here was deliberate and is preserved: no top-N, no
# sampling, no truncation. What changed is a bound derived from the script's
# OWN invariant, below in section 3:
#
#     if released_at < proc_started: continue
#         # a DONE predating the process is not its own
#
# A DONE older than the OLDEST live candidate process therefore cannot produce
# a finding — not "is unlikely to", cannot, by that line. So messages older
# than that are skipped without losing a single detection. Critically the bound
# STRETCHES: a worker released three days ago and still alive has a three-day
# proc_started, so its DONE is still in range. That is the case the reaper
# exists to catch, and a naive "ignore messages older than 30min/24h" bound
# would have deleted exactly it. This one cannot.
#
# CONSERVATIVE BY CONSTRUCTION, not by margin (fable-reviewer, 2026-08-12):
# the cutoff is derived from the FULL candidate-process set, which is a SUPERSET
# of the processes that could actually yield a finding (most are filtered out
# later by the environ/agent-dir checks). So the oldest member of that set is at
# least as old as the oldest process that matters, and the cutoff can only ever
# land OLDER than strictly necessary — never newer. That is the real reason this
# is safe. The margins below are belt-and-braces on top of it, not the argument.
#
# Safety margins, all in the conservative direction (keep too much, never too
# little):
#   - CUTOFF_MARGIN backs the bound off by an hour against clock skew between
#     `ps` etimes and message timestamps.
#   - The filter is on FILE MTIME, a proxy for the message timestamp. mtime can
#     only be >= the moment the content was written, so an mtime-based keep
#     never drops a message whose timestamp is inside the window. It can only
#     keep extra.
#   - If there are no live candidate processes, or stat() fails, the bound is
#     disabled and everything is scanned. Fail toward MORE scanning.
#
# WHY THIS EXISTS: `processed/` grows forever — 54,265 messages / 219MB on
# 2026-08-12 — and every run json.load()ed all of it. Cold-cache that exceeded
# five minutes; warm it was 57s. The cost was unbounded in the number of
# messages the fleet has ever sent, while the useful window is bounded by how
# long a process has been alive.
CUTOFF_MARGIN = datetime.timedelta(hours=1)
oldest_proc_age = max((p['etimes'] for p in procs), default=None)
if oldest_proc_age is None:
    mtime_cutoff = None
else:
    mtime_cutoff = (now - datetime.timedelta(seconds=oldest_proc_age)
                        - CUTOFF_MARGIN).timestamp()

done = {}   # worker name -> latest datetime
scanned = 0
skipped_old = 0
for box in ('processed','inbox','inflight'):
    for path in glob.glob(f'{ROOT}/{box}/*/*.json'):
        if mtime_cutoff is not None:
            try:
                if os.path.getmtime(path) < mtime_cutoff:
                    skipped_old += 1
                    continue
            except OSError:
                pass          # cannot stat -> scan it; never skip on error
        scanned += 1
        try:
            j = json.load(open(path))
        except Exception:
            continue
        frm = str(j.get('from') or '')
        txt = str(j.get('text') or '')
        if not frm or not re.search(r'\bDONE\b', txt):
            continue
        ts = j.get('timestamp') or ''
        try:
            dt = datetime.datetime.fromisoformat(ts.replace('Z','+00:00'))
        except Exception:
            continue
        if frm not in done or dt > done[frm]:
            done[frm] = dt

# ── 3. Match live processes to a released worker via CMDLINE ────────────────
#
# FIRST REPORT-ONLY RUN (2026-08-11) FLAGGED FIVE LIVE AGENTS — pm, lit_agent,
# media, ma_studio_agency, writer — as "released-but-alive". With --kill that
# would have terminated five production agents. Three defects, all fixed here:
#
#   a. EVERY agent sends DONE messages, not just workers. The sender set was the
#      whole fleet, so any agent that ever said DONE became a reap candidate.
#   b. SUBSTRING matching on short names: "pm" matches almost any cmdline.
#      Now word-boundary anchored, and names under 6 chars are never matched
#      by name alone — they need the PM task id.
#   c. NO TEMPORAL SANITY: "released 47625min ago" (33 days) was matched to a
#      process alive 2.1h. A DONE that predates the process start cannot be
#      that process's DONE. The release must fall INSIDE the process lifetime.
#
# The invariant that makes this safe: a worker is a process whose spawn prompt
# marks it as one, whose identity match is strong, and whose DONE arrived while
# it was running.
# IDENTITY COMES FROM /proc/<pid>/environ, NOT FROM PROMPT TEXT.
#
# The daemon stamps CTX_AGENT_NAME at spawn: agent-manager.ts:1001 puts the
# worker's name in CtxEnv.agentName, and agent-pty.ts:72 maps that to the
# process environment. Workers take the same path as agents, so a worker's own
# name is a daemon-set fact, not something inferred from its spawn prompt.
#
# An earlier version gated on prompt phrasing ("build worker", "ONE task").
# That worked but coupled the reaper to how prompts happen to be written.
# Reading environ removes the coupling and — the decisive part — needs no
# cortextos release, so it also covers workers spawned before this script.
#
# WORKER vs AGENT: CTX_AGENT_NAME is set for both, so it identifies but does not
# classify. CTX_AGENT_DIR does: agents live under orgs/<org>/agents/<name>,
# workers spawn in a repo or workspace dir.
#
# EDGE, and it is CONVENTIONAL not ENFORCED (fable-reviewer, 2026-08-11):
# spawn-worker permits any dir under the daemon cwd, which INCLUDES
# orgs/*/agents/*. A worker deliberately spawned inside an agent directory
# classifies as an agent and is INVISIBLE to this reaper. That is a false
# negative — the safe direction — and has never been done in practice, but the
# boundary is a convention, not a guarantee.
AGENT_DIR_RE = re.compile(r'/orgs/[^/]+/agents/[^/]+/?$')

def proc_env(pid):
    try:
        raw = open(f'/proc/{pid}/environ','rb').read().decode('utf-8','replace')
    except Exception:
        return {}
    out = {}
    for item in raw.split('\0'):
        if '=' in item:
            k, v = item.split('=', 1)
            out[k] = v
    return out

findings = []
skipped_agents = 0
for p in procs:
    env = proc_env(p['pid'])
    wname = env.get('CTX_AGENT_NAME', '')
    wdir  = env.get('CTX_AGENT_DIR', '')
    if not wname:
        continue                       # no daemon identity: not ours to reap
    if AGENT_DIR_RE.search(wdir.rstrip('/')):
        skipped_agents += 1
        continue                       # lives in an agent dir -> an agent
    released_at = done.get(wname)
    if released_at is None:
        continue                       # never declared DONE -> still working
    proc_started = now - datetime.timedelta(seconds=p['etimes'])
    if released_at < proc_started:
        continue                       # a DONE predating the process is not its own
    matched = wname
    if matched is None:
        continue
    age_min = (now - released_at).total_seconds() / 60
    findings.append(dict(pid=p['pid'], worker=matched, rss_mb=p['rss_mb'],
                         alive_h=round(p['etimes']/3600, 1),
                         released_at=released_at.strftime('%Y-%m-%dT%H:%M:%SZ'),
                         min_since_release=round(age_min)))

print(f"worker-reaper: {len(procs)} claude processes | {skipped_agents} agents skipped (agent dir) | "
      f"{scanned} bus messages scanned, {skipped_old} skipped as older than the oldest live process "
      f"(bounded, NOT capped — see section 2) | "
      f"{len(done)} senders with a DONE | {len(findings)} released-but-alive")
print(f"  mode: {'KILL' if KILL else 'REPORT-ONLY'}  min-age: {MIN_AGE}min")

if not findings:
    print("  nothing released-but-alive. No action.")
    log(dict(event='scan', mode='kill' if KILL else 'report',
             procs=len(procs), findings=0))
    sys.exit(0)

for f in sorted(findings, key=lambda x: -x['min_since_release']):
    eligible = f['min_since_release'] >= MIN_AGE
    verdict = 'REAPABLE' if eligible else f"too recent (<{MIN_AGE}min)"
    print(f"  pid {f['pid']:<9} {f['worker']:<26} alive {f['alive_h']:>5}h "
          f"{f['rss_mb']:>5}MB  released {f['min_since_release']:>5}min ago  -> {verdict}")
    if not (KILL and eligible):
        continue
    # PID-verify immediately before signalling: the pid could have exited, or
    # worse, been recycled onto a different process since the scan began.
    try:
        cur = open(f'/proc/{f["pid"]}/cmdline','rb').read().replace(b'\0',b' ').decode('utf-8','replace')
    except Exception:
        print(f"    pid {f['pid']} vanished before kill — skipping")
        log(dict(event='skip_vanished', **f)); continue
    suffix = f['worker'].rsplit('-',1)[-1]
    if f['worker'] not in cur and suffix not in cur:
        print(f"    pid {f['pid']} NO LONGER MATCHES {f['worker']} — PID REUSE, skipping")
        log(dict(event='skip_pid_reuse', **f)); continue
    log(dict(event='kill_attempt', **f))
    try:
        os.kill(int(f['pid']), signal.SIGTERM)
        print(f"    SIGTERM -> pid {f['pid']}")
        log(dict(event='killed', **f))
    except Exception as e:
        print(f"    kill FAILED pid {f['pid']}: {e}")
        log(dict(event='kill_failed', error=str(e), **f))
PYEOF
exit 0
