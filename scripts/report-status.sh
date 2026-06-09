#!/bin/bash
# Usage: report-status.sh <type> <reason>
TYPE="${1:-up}"
REASON="${2:-continuation}"
STATE_DIR="${CTX_ROOT}/state/${CTX_AGENT_NAME}"
RESTART_FILE="${STATE_DIR}/.restart-count"
mkdir -p "$STATE_DIR"
RESTART_COUNT=$(( $(cat "$RESTART_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$RESTART_COUNT" > "$RESTART_FILE"
SESSION_START=$(date -u +%s)
cortextos bus send-message health normal "[STATUS] ${TYPE} agent=${CTX_AGENT_NAME} reason=${REASON} session_started=${SESSION_START} restart_count=${RESTART_COUNT}"
