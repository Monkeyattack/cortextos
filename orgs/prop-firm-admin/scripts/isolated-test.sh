#!/usr/bin/env bash
# isolated-test.sh — run ANY test that might write cortextOS state, against a scratch
# instance instead of production. Fail-closed.
#
# WHY THIS IS A SCRIPT AND NOT A LESSON
# The same mistake has now been made twice by the same agent in two days:
#   2026-08-13  tested `update-heartbeat` failure behaviour under a scratch CTX_ROOT.
#               CTX_ROOT is NOT honoured by bus state resolution (it resolves via
#               homedir() + CTX_INSTANCE_ID), so it overwrote a live agent's heartbeat
#               and created a phantom agent directory in production.
#   2026-08-14  tested a wake-on-alert SCRIPT with a bogus AGENT value. Same outcome:
#               phantom state/ and logs/ directories in production.
# The 2026-08-13 lesson was written as "use a separate CTX_INSTANCE_ID for bus
# commands", so it did not fire the second time, because the second time the thing
# under test was a shell script. Per the standing rule, a guardrail that has failed
# twice ships as a fail-closed check rather than more prose.
#
# WHAT IT GUARANTEES
#   - CTX_INSTANCE_ID is forced to a scratch instance, so every state/log write lands
#     under ~/.cortextos/<scratch>/ and never under the production instance.
#   - CTX_ROOT is scrubbed rather than trusted. It looks like an isolation boundary
#     and is not one; leaving it set invites exactly the 2026-08-13 error.
#   - REFUSES TO RUN if the caller tries to point it at the production instance.
#   - Cleans the scratch instance up afterwards, and reports what it removed rather
#     than deleting silently.
#
# USAGE
#   isolated-test.sh <command> [args...]
#   isolated-test.sh bash devops-heartbeat-stamp.sh
#   TEST_INSTANCE=my-case isolated-test.sh cortextos bus update-heartbeat "x"
#
# The command still needs CTX_AGENT_NAME / CTX_ORG if it reads them — set those in
# your invocation. Only the INSTANCE is forced.

set -uo pipefail

PROD_INSTANCE="${PROD_INSTANCE:-default}"
TEST_INSTANCE="${TEST_INSTANCE:-isolated-test}"

if [ $# -eq 0 ]; then
  echo "usage: isolated-test.sh <command> [args...]" >&2
  exit 2
fi

# Fail closed on any attempt to aim this at production. Checked BEFORE anything runs,
# because the whole point is that the unsafe case must never reach execution.
if [ "$TEST_INSTANCE" = "$PROD_INSTANCE" ]; then
  echo "isolated-test: REFUSING — TEST_INSTANCE ('$TEST_INSTANCE') is the production instance." >&2
  echo "isolated-test: pick a different TEST_INSTANCE. That is the entire purpose of this wrapper." >&2
  exit 3
fi

TEST_ROOT="${HOME}/.cortextos/${TEST_INSTANCE}"
case "$TEST_ROOT" in
  "${HOME}/.cortextos/${PROD_INSTANCE}"|"${HOME}/.cortextos"|"${HOME}"|"/"|"")
    echo "isolated-test: REFUSING — resolved scratch root '$TEST_ROOT' is unsafe to create or delete." >&2
    exit 3
    ;;
esac

mkdir -p "$TEST_ROOT" || { echo "isolated-test: cannot create $TEST_ROOT" >&2; exit 3; }

echo "isolated-test: instance='$TEST_INSTANCE' root='$TEST_ROOT'  (production '$PROD_INSTANCE' untouched)"

# CTX_ROOT is unset, not overridden: bus state resolution ignores it, so a value here
# is at best inert and at worst a false sense of isolation.
env -u CTX_ROOT CTX_INSTANCE_ID="$TEST_INSTANCE" "$@"
RC=$?

echo "isolated-test: command exit=$RC"

# Report before removing. A cleanup that prints nothing cannot be audited, and the
# contents are usually the evidence the test was trying to produce.
if [ -d "$TEST_ROOT" ]; then
  echo "isolated-test: scratch contents created by this run:"
  find "$TEST_ROOT" -mindepth 1 -maxdepth 3 2>/dev/null | sed 's/^/  /' | head -40
  rm -rf "$TEST_ROOT"
  if [ -d "$TEST_ROOT" ]; then
    echo "isolated-test: WARNING scratch root still present after cleanup: $TEST_ROOT" >&2
  else
    echo "isolated-test: scratch removed."
  fi
fi

exit $RC
