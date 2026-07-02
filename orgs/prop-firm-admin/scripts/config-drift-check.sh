#!/usr/bin/env bash
# config-drift-check.sh — disk-read fleet config drift scanner.
#
# Run by the health agent on its heartbeat. Reports config drift and exits 1 if any
# is found (0 = clean), so health can alert on a non-zero exit.
#
# PRINCIPLE: verify the ARTIFACT on disk, never an agent's self-report. Three agents
# (workspace, waldorf, statler) reported SOUL.md fills as "done" that never persisted
# to disk (2026-07-02 config audit) — this scanner reads the files, not the claims.
#
# Checks (content-based, robust as the canonical template evolves — not checksums):
#   1. Unfilled {{placeholders}} in any bootstrap .md      (undefined behavior)
#   2. Forbidden/deprecated cron flow in CLAUDE.md/AGENTS.md (contradicts daemon-managed crons)
#   3. Wrong crons.json path in CLAUDE.md/AGENTS.md         (docs-vs-code: real path is .cortextOS/state/agents/<agent>/)
#   4. Org-level skills missing YAML frontmatter name:      (broken skill registration)
#
# Owner: health (invocation) / fable-reviewer (authored, 2026-07-02).

set -uo pipefail
ROOT="${CTX_FRAMEWORK_ROOT:-/home/claude-dev/cortextos}"

# Two severities so health pages on what's NEW/actionable, not on known backlog:
#   ACTIONABLE — undefined behavior / broken skill → drives the non-zero exit (alert now).
#   BACKLOG    — forbidden-cron + wrong-crons-path are a known fleet-wide convergence
#                item (config-audit M1/M2). Reported as a COUNT only; does NOT page,
#                so it can't cause alert fatigue while M2 is pending. Should trend to 0.
actionable=0
backlog=0
actionable_report=""
backlog_report=""

for dir in "$ROOT"/orgs/*/agents/*; do
  [ -d "$dir" ] || continue
  agent="$(basename "$dir")"
  org="$(basename "$(dirname "$(dirname "$dir")")")"

  # 1. ACTIONABLE — unfilled template placeholders (undefined behavior)
  for f in CLAUDE SOUL GUARDRAILS AGENTS IDENTITY USER SYSTEM; do
    [ -f "$dir/$f.md" ] || continue
    if grep -qE '\{\{[a-z_]+\}\}' "$dir/$f.md" 2>/dev/null; then
      ph="$(grep -oE '\{\{[a-z_]+\}\}' "$dir/$f.md" | sort -u | tr '\n' ' ')"
      actionable_report="${actionable_report}
  [${org}/${agent}] PLACEHOLDER  $f.md: ${ph}"
      actionable=$((actionable + 1))
    fi
  done

  # 2/3. BACKLOG — forbidden cron flow + wrong crons.json path (M1/M2 convergence)
  for f in CLAUDE AGENTS; do
    [ -f "$dir/$f.md" ] || continue
    if grep -qEi 'run CronList|Restore crons from .?config\.json|Set up once per session via .?/loop|recreated from config' "$dir/$f.md" 2>/dev/null; then
      backlog_report="${backlog_report}
  [${org}/${agent}] FORBIDDEN-CRON  $f.md"
      backlog=$((backlog + 1))
    fi
    if grep -qF 'state/${CTX_AGENT_NAME}/crons.json' "$dir/$f.md" 2>/dev/null \
       || grep -qF "state/${agent}/crons.json" "$dir/$f.md" 2>/dev/null; then
      backlog_report="${backlog_report}
  [${org}/${agent}] WRONG-CRONS-PATH  $f.md"
      backlog=$((backlog + 1))
    fi
  done
done

# 4. ACTIONABLE — org-level skills missing YAML frontmatter name:
for skill in "$ROOT"/orgs/*/.claude/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  if ! head -1 "$skill" | grep -qE '^---' || ! head -10 "$skill" | grep -qE '^name:'; then
    actionable_report="${actionable_report}
  MISSING-FRONTMATTER  ${skill#"$ROOT"/}"
    actionable=$((actionable + 1))
  fi
done

echo "=== config drift-check  $(date -u +%Y-%m-%dT%H:%M:%SZ)  (disk-read) ==="
echo "ACTIONABLE: ${actionable}   BACKLOG(M1/M2): ${backlog}"
if [ "$actionable" -gt 0 ]; then
  printf 'ACTIONABLE (alert):%b\n' "$actionable_report"
fi
if [ "$backlog" -gt 0 ]; then
  printf 'BACKLOG (M1/M2 convergence — track, do not page):%b\n' "$backlog_report"
fi
[ "$actionable" -eq 0 ] && [ "$backlog" -eq 0 ] && echo "OK — no config drift across the fleet."
# Exit non-zero ONLY on actionable drift, so health pages on new/undefined-behavior
# issues but not on the known M1/M2 backlog. Backlog trending up would still show in
# the ACTIONABLE=0/BACKLOG=N line for health to watch.
[ "$actionable" -gt 0 ] && exit 1
exit 0
