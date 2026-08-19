#!/usr/bin/env bash
# Monitor Higgsfield credits and fal.ai prepaid balance.

set -uo pipefail

readonly HIGGSFIELD_THRESHOLD="20"
readonly FAL_THRESHOLD="5"
readonly CHAT_ID="6585156851"
readonly FAL_ENV_FILE="/home/claude-dev/repos/ai-theist/.env.local"
readonly DEVOPS_ENV_FILE="/home/claude-dev/cortextos/orgs/prop-firm-admin/agents/devops/.env"
readonly HIGGSFIELD_BIN="${HIGGSFIELD_BIN:-/home/claude-dev/.local/bin/higgsfield}"
readonly CORTEXTOS_BIN="${CORTEXTOS_BIN:-cortextos}"
readonly FAL_BALANCE_URL="https://rest.alpha.fal.ai/billing/user_balance"

errors=()
alerts=()
higgsfield_balance=""
fal_balance=""

read_env_value() {
  local key="$1"
  local file="$2"
  [[ -r "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

is_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_below() {
  awk -v value="$1" -v threshold="$2" 'BEGIN { exit !(value < threshold) }'
}

send_telegram() {
  local message="$1"
  local response

  if [[ -z "${BOT_TOKEN:-}" ]]; then
    BOT_TOKEN=$(read_env_value BOT_TOKEN "$DEVOPS_ENV_FILE" || true)
  fi
  if [[ -z "${BOT_TOKEN:-}" ]]; then
    echo "ERROR: BOT_TOKEN not found in $DEVOPS_ENV_FILE" >&2
    return 1
  fi

  response=$(curl -fsS --connect-timeout 5 --max-time 15 \
    -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${message}") || return 1
  jq -e '.ok == true' >/dev/null <<<"$response"
}

check_higgsfield() {
  local response

  if [[ ! -x "$HIGGSFIELD_BIN" ]]; then
    errors+=("Higgsfield CLI not executable: $HIGGSFIELD_BIN")
    return
  fi

  # The official Higgsfield CLI uses its authenticated account API. Higgsfield
  # does not currently expose a public API-key balance endpoint.
  if ! response=$("$HIGGSFIELD_BIN" account status --json 2>/dev/null); then
    errors+=("Higgsfield account API request failed")
    return
  fi

  higgsfield_balance=$(jq -er '.credits | numbers' <<<"$response" 2>/dev/null || true)
  if [[ -z "$higgsfield_balance" ]] || ! is_number "$higgsfield_balance"; then
    errors+=("Higgsfield response did not contain a numeric credit balance")
    higgsfield_balance=""
    return
  fi

  if is_below "$higgsfield_balance" "$HIGGSFIELD_THRESHOLD"; then
    alerts+=("Higgsfield: ${higgsfield_balance} credits (threshold: ${HIGGSFIELD_THRESHOLD})")
  fi
}

check_fal() {
  local response

  if [[ -z "${FAL_KEY:-}" ]]; then
    FAL_KEY=$(read_env_value FAL_KEY "$FAL_ENV_FILE" || true)
  fi
  if [[ -z "${FAL_KEY:-}" ]]; then
    errors+=("FAL_KEY not found in $FAL_ENV_FILE")
    return
  fi

  if ! response=$(curl -fsS --connect-timeout 5 --max-time 20 \
    -H "Authorization: Key ${FAL_KEY}" "$FAL_BALANCE_URL"); then
    errors+=("fal.ai balance API request failed")
    return
  fi

  fal_balance=$(jq -er 'if type == "number" then . elif type == "object" then (.balance // .credits) else empty end | numbers' \
    <<<"$response" 2>/dev/null || true)
  if [[ -z "$fal_balance" ]] || ! is_number "$fal_balance"; then
    errors+=("fal.ai response did not contain a numeric dollar balance")
    fal_balance=""
    return
  fi

  if is_below "$fal_balance" "$FAL_THRESHOLD"; then
    alerts+=("fal.ai: \$${fal_balance} (threshold: \$${FAL_THRESHOLD})")
  fi
}

log_result() {
  local status="ok"
  local severity="info"
  local meta

  if (( ${#errors[@]} > 0 )); then
    status="error"
    severity="error"
  elif (( ${#alerts[@]} > 0 )); then
    status="low_balance"
    severity="warning"
  fi

  meta=$(jq -cn \
    --arg agent "chief" \
    --arg status "$status" \
    --arg higgsfield_balance "${higgsfield_balance:-unavailable}" \
    --arg fal_balance "${fal_balance:-unavailable}" \
    --argjson higgsfield_threshold "$HIGGSFIELD_THRESHOLD" \
    --argjson fal_threshold "$FAL_THRESHOLD" \
    --arg errors "$(IFS='; '; echo "${errors[*]-}")" \
    '{agent:$agent,status:$status,higgsfield_credits:$higgsfield_balance,fal_usd:$fal_balance,higgsfield_threshold:$higgsfield_threshold,fal_threshold_usd:$fal_threshold,errors:$errors}')

  "$CORTEXTOS_BIN" bus log-event action credit_balance_checked "$severity" --meta "$meta"
}

main() {
  local exit_code=0
  local alert_message

  for dependency in curl jq awk; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
      echo "ERROR: required command not found: $dependency" >&2
      exit 1
    fi
  done

  check_higgsfield
  check_fal

  if ! log_result; then
    errors+=("failed to log result to cortextOS activity feed")
    exit_code=1
  fi

  if (( ${#alerts[@]} > 0 )); then
    alert_message=$(printf 'CREDIT BALANCE ALERT\n%s\n' "$(printf '%s\n' "${alerts[@]}")")
    if ! send_telegram "$alert_message"; then
      echo "ERROR: failed to send low-balance Telegram alert" >&2
      exit_code=1
    fi
  fi

  if (( ${#errors[@]} > 0 )); then
    printf 'ERROR: %s\n' "${errors[@]}" >&2
    exit_code=1
  fi

  printf 'Higgsfield: %s credits (threshold: %s)\n' "${higgsfield_balance:-unavailable}" "$HIGGSFIELD_THRESHOLD"
  printf 'fal.ai: $%s (threshold: $%s)\n' "${fal_balance:-unavailable}" "$FAL_THRESHOLD"
  if (( ${#alerts[@]} == 0 && ${#errors[@]} == 0 )); then
    echo "Status: OK"
  elif (( ${#alerts[@]} > 0 )); then
    echo "Status: LOW BALANCE"
  else
    echo "Status: ERROR"
  fi

  return "$exit_code"
}

main "$@"
