#!/usr/bin/env bash
# log-job.sh — append a job application record to jobs.json
# Usage: log-job.sh <company> <role> <score> <resume_file> [status]
# Status defaults to "filed"
set -euo pipefail

JOBS_FILE="${CTX_ROOT:-/home/claude-dev/cortextos}/orgs/prop-firm-admin/agents/reserve/jobs.json"

COMPANY="$1"
ROLE="$2"
SCORE="$3"
RESUME_FILE="$4"
STATUS="${5:-filed}"
DATE_FILED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Read existing records, append new one, write back atomically
TMPFILE=$(mktemp)
python3 - <<PYEOF
import json, sys

try:
    with open("$JOBS_FILE") as f:
        records = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    records = []

records.append({
    "company": "$COMPANY",
    "role": "$ROLE",
    "score": float("$SCORE"),
    "resume_file": "$RESUME_FILE",
    "status": "$STATUS",
    "date_filed": "$DATE_FILED"
})

with open("$TMPFILE", "w") as f:
    json.dump(records, f, indent=2)
PYEOF

mv "$TMPFILE" "$JOBS_FILE"
echo "Logged: $COMPANY — $ROLE ($STATUS)"
