#!/usr/bin/env bash
# send-usage-stats.sh — Anthropic usage digest → Telegram (chat 6585156851)
#
# Sources:
#   1. OAuth usage (5h/7d utilization) via `cortextos bus check-usage-api`.
#      Token resolved from CLAUDE_CODE_OAUTH_TOKEN or ~/.claude/.credentials.json.
#   2. Admin API cost/usage reports — only if ANTHROPIC_ADMIN_API_KEY is set
#      (env, agent .env, or Vault secret/anthropic key admin_api_key).
#      Requires an ORG ADMIN key minted in the Anthropic console.
#
# Cron-safe: no interactive input, exits non-zero only on total failure.
set -u

CHAT_ID=6585156851
CORTEXTOS=${CORTEXTOS_BIN:-cortextos}
CRED_FILE="$HOME/.claude/.credentials.json"
ENV_FILE="/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/devops/.env"

# --- Telegram bot token (cron env is bare) ---
if [ -z "${BOT_TOKEN:-}" ] && [ -f "$ENV_FILE" ]; then
  BOT_TOKEN=$(grep -m1 '^BOT_TOKEN=' "$ENV_FILE" | cut -d'=' -f2- || true)
  export BOT_TOKEN
fi

# --- OAuth token for check-usage-api ---
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$CRED_FILE" ]; then
  CLAUDE_CODE_OAUTH_TOKEN=$(python3 -c "import json,sys;print(json.load(open('$CRED_FILE'))['claudeAiOauth']['accessToken'])" 2>/dev/null || true)
  export CLAUDE_CODE_OAUTH_TOKEN
fi

# --- Source 1: OAuth utilization ---
oauth_lines=''
usage_out=$("$CORTEXTOS" bus check-usage-api 2>&1)
if [ $? -eq 0 ]; then
  five=$(printf '%s\n' "$usage_out" | awk -F': *' '/5h utilization/{print $2}')
  seven=$(printf '%s\n' "$usage_out" | awk -F': *' '/7d utilization/{print $2}')
  oauth_lines="5h window: ${five:-?} used
7d window: ${seven:-?} used"
else
  oauth_lines='OAuth usage: unavailable (check-usage-api failed)'
fi

# --- Admin key discovery ---
ADMIN_KEY=${ANTHROPIC_ADMIN_API_KEY:-}
if [ -z "$ADMIN_KEY" ] && [ -f "$ENV_FILE" ]; then
  ADMIN_KEY=$(grep -m1 '^ANTHROPIC_ADMIN_API_KEY=' "$ENV_FILE" | cut -d'=' -f2- || true)
fi
if [ -z "$ADMIN_KEY" ] && command -v vault >/dev/null 2>&1; then
  ADMIN_KEY=$(VAULT_SKIP_VERIFY=1 vault kv get -field=admin_api_key secret/anthropic 2>/dev/null || true)
fi

# --- Source 2: Admin API cost + token counts ---
admin_lines='Cost/tokens: n/a (admin key pending)'
if [ -n "$ADMIN_KEY" ]; then
  today_utc=$(date -u +%Y-%m-%dT00:00:00Z)
  week_ago=$(date -u -d '7 days ago' +%Y-%m-%dT00:00:00Z)
  hdrs=(-H "anthropic-version: 2023-06-01" -H "anthropic-beta: usage-reports-2025-01-24" -H "x-api-key: $ADMIN_KEY")

  cost_json=$(curl -sf --max-time 30 "${hdrs[@]}" \
    "https://api.anthropic.com/v1/organizations/cost_report?starting_at=${week_ago}&group_by%5B%5D=workspace_id" || true)
  usage_json=$(curl -sf --max-time 30 "${hdrs[@]}" \
    "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=${week_ago}&bucket_width=1d" || true)

  admin_lines=$(python3 - "$cost_json" "$usage_json" <<'PYEOF'
import json, sys
cost_raw, usage_raw = sys.argv[1], sys.argv[2]
lines = []
try:
    data = json.loads(cost_raw)
    total = 0.0
    for bucket in data.get('data', []):
        for r in bucket.get('results', []):
            amt = r.get('amount')
            if isinstance(amt, dict):
                total += float(amt.get('value', 0))
            elif amt is not None:
                total += float(amt)
    lines.append('7d API cost: $%.2f' % total)
except Exception:
    lines.append('7d API cost: parse error')
try:
    data = json.loads(usage_raw)
    tin = tout = 0
    for bucket in data.get('data', []):
        for r in bucket.get('results', []):
            tin += int(r.get('uncached_input_tokens', 0)) + int(r.get('cache_read_input_tokens', 0)) + int(r.get('cache_creation_input_tokens', 0) if isinstance(r.get('cache_creation_input_tokens', 0), int) else 0)
            tout += int(r.get('output_tokens', 0))
    def fmt(n):
        return '%.1fM' % (n/1e6) if n >= 1e6 else '%.0fK' % (n/1e3)
    lines.append('7d tokens: %s in / %s out' % (fmt(tin), fmt(tout)))
except Exception:
    lines.append('7d tokens: parse error')
print('\n'.join(lines))
PYEOF
)
  [ -z "$admin_lines" ] && admin_lines='Cost/tokens: admin API request failed'
fi

# --- Compose + send (single-quoted safe: message built in a var, sent --plain-text) ---
stamp=$(TZ=America/Chicago date '+%b %-d %-I:%M%p CT')
msg="Anthropic usage — ${stamp}
${oauth_lines}
${admin_lines}"

"$CORTEXTOS" bus send-telegram --plain-text "$CHAT_ID" "$msg"
