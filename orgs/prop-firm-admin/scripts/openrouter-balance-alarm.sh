#!/usr/bin/env bash
# openrouter-balance-alarm.sh — alert before OpenRouter credit runs out.
#
# WHY: Chris topped up $10 on 2026-08-04 with NO auto-reload. That is a hard stop —
# when it is gone, every codex-runtime agent and worker dies the same way OpenAI did
# (chatboss-codex 404/429 loop, codex spawn-workers returning zero output). The whole
# point of this alarm is to give warning BEFORE that, not to discover it afterwards.
#
# *** SOURCE NOTE — /api/v1/key DOES NOT CARRY THE BALANCE. ***
#   That endpoint returns limit: null and limit_remaining: null on this account, so a
#   monitor built on it would read "no limit" and never alert. The authoritative source
#   is /api/v1/credits -> {total_credits, total_usage}. Remaining = credits - usage.
#   Verified 2026-08-04: key endpoint nulls, credits endpoint returned 10 / 0.3867.
#
# FAIL-CLOSED, same rule as every check in the monitoring SOW: if the balance cannot be
# READ, that is UNDETERMINED (exit 2) — never "balance fine". A billing alarm that goes
# quiet because it is broken is indistinguishable from one that is quiet because there
# is money, and the failure it exists to prevent is exactly a silent stop.
#
# usage: openrouter-balance-alarm.sh [--warn-usd N] [--quiet]
# exit 0 = balance above warn threshold
# exit 1 = balance AT or BELOW warn threshold (real alarm)
# exit 2 = UNDETERMINED — could not read balance
set -uo pipefail

WARN_USD=2          # chief's threshold 2026-08-04
QUIET=0
ENV_FILE="${CTX_AGENT_DIR:-/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/devops}/.env"

while [ $# -gt 0 ]; do
  case "$1" in
    --warn-usd) WARN_USD="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) echo "[or-balance] UNDETERMINED: unknown arg $1"; exit 2 ;;
  esac
done

case "$WARN_USD" in ''|*[!0-9.]*) echo "[or-balance] UNDETERMINED: --warn-usd must be numeric, got '${WARN_USD}'"; exit 2 ;; esac

KEY=$(grep -oP '^OPENROUTER_API_KEY=\K.*' "$ENV_FILE" 2>/dev/null | head -1 | tr -d '"'"'"' \r')
if [ -z "$KEY" ]; then
  echo "[or-balance] UNDETERMINED: no OPENROUTER_API_KEY in $ENV_FILE — cannot check, NOT reporting all-clear"
  exit 2
fi

body=$(curl -s -m 30 -H "Authorization: Bearer $KEY" https://openrouter.ai/api/v1/credits 2>/dev/null)
if [ -z "$body" ]; then
  echo "[or-balance] UNDETERMINED: no response from /api/v1/credits — NOT reporting all-clear"
  exit 2
fi

read -r credits usage <<<"$(printf '%s' "$body" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin).get('data',{})
    c=d.get('total_credits'); u=d.get('total_usage')
    # Both must be real numbers. A missing field is UNDETERMINED, never 0.
    if not isinstance(c,(int,float)) or not isinstance(u,(int,float)): print('ERR ERR')
    else: print(c,u)
except Exception:
    print('ERR ERR')
" 2>/dev/null)"

if [ "$credits" = "ERR" ] || [ -z "${usage:-}" ]; then
  echo "[or-balance] UNDETERMINED: could not parse total_credits/total_usage from /api/v1/credits — NOT reporting all-clear"
  [ "$QUIET" -eq 0 ] && echo "  raw: $(printf '%s' "$body" | head -c 200)"
  exit 2
fi

remaining=$(python3 -c "print(f'{float($credits)-float($usage):.4f}')")
pct=$(python3 -c "c=float($credits); print(f'{(float($remaining)/c*100):.1f}' if c>0 else '0.0')")

echo "[or-balance] $(date -u +%Y-%m-%dT%H:%M:%SZ)  credits=\$${credits}  used=\$${usage}  remaining=\$${remaining} (${pct}%)  warn_at=\$${WARN_USD}"

# ── Burn-rate ledger ─────────────────────────────────────────────────────────
# The script previously persisted NOTHING, so every question about burn rate had
# to be answered from the cumulative average since the last top-up — total spend
# over elapsed days. That averages busy weekdays with idle nights and is wrong in
# both directions depending on when you ask.
#
# 2026-08-11: that average gave $1.045/day and a "crosses warn today" call. Two
# actual readings 4h apart gave $0.288/day and ~22h to warn — 3.6x out. The
# correction was only possible because two readings happened to exist in a
# session transcript. Append them so the next one does not depend on luck.
#
# One JSON object per run. Rate is derived at read time from any two rows, so no
# state beyond the file itself.
LEDGER="${OR_BALANCE_LEDGER:-$HOME/.cortextos/default/state/devops/openrouter-balance.jsonl}"
if mkdir -p "$(dirname "$LEDGER")" 2>/dev/null; then
  printf '{"ts":"%s","credits":%s,"used":%s,"remaining":%s,"warn_at":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$credits" "$usage" "$remaining" "$WARN_USD" \
    >> "$LEDGER" 2>/dev/null || true
fi

if [ "$(python3 -c "print(1 if float($remaining) <= float($WARN_USD) else 0)")" = "1" ]; then
  echo "[or-balance] ALARM: OpenRouter balance \$${remaining} is at or below \$${WARN_USD}."
  echo "[or-balance] NO AUTO-RELOAD IS CONFIGURED — when this reaches zero every codex agent and worker stops, the same failure mode as the OpenAI exhaustion on 2026-08-04."
  echo "[or-balance] This needs Chris: only he can top up. Do not attempt to add credits."
  exit 1
fi
exit 0
