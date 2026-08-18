#!/bin/bash
# Session-size watchdog — fable-reviewer context-hygiene implementation 2026-08-03.
# Runs from system crontab (daemon-independent, same principle as dead-fleet alerting).
# Alerts chief via bus when any LIVE session transcript exceeds threshold.
THRESHOLD_MB=25
ALERTED_STATE=/tmp/session-watchdog-alerted
touch "$ALERTED_STATE"
findings=""
for f in $(find /home/claude-dev/.claude/projects -name "*.jsonl" -mmin -60 -size +${THRESHOLD_MB}M 2>/dev/null); do
  sz=$(du -m "$f" | cut -f1)
  agent=$(echo "$f" | sed 's#.*/-home-claude-dev-cortextos-orgs-[a-z-]*-agents-##;s#/.*##;s#-home-claude-dev-##;s#/.*##' | cut -d/ -f1)
  key=$(echo "$f" | md5sum | cut -c1-8)
  # alert once per session per 6h
  if ! grep -q "$key:$(date +%Y%m%d-%H | cut -c1-11)" "$ALERTED_STATE" 2>/dev/null; then
    last=$(grep "$key" "$ALERTED_STATE" | tail -1 | cut -d: -f2)
    now_h=$(date +%s); [ -n "$last" ] && age=$(( (now_h - last) / 3600 )) || age=99
    if [ "$age" -ge 6 ]; then
      findings="$findings $agent(${sz}MB)"
      echo "$key:$(date +%s)" >> "$ALERTED_STATE"
    fi
  fi
done
if [ -n "$findings" ]; then
  cortextos bus send-message chief normal "SESSION-SIZE WATCHDOG: live session(s) over ${THRESHOLD_MB}MB —${findings}. Context degradation risk (deep-session failure class). Recommend early hard-restart w/ compacted handoff for the flagged agent(s); daily reset covers all agents from tomorrow 7:30-8:00 AM CT." 2>/dev/null
fi
