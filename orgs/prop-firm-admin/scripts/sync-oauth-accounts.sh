#!/usr/bin/env bash
# Mirror the Claude Code Max-account ACCESS token into state/oauth/accounts.json
# so `cortextos bus check-usage-api` can measure real 5h/7d utilization.
#
# DELIBERATE DESIGN: refresh_token is left EMPTY. Refresh tokens are one-time
# use and ~/.claude/.credentials.json (Claude Code itself) owns the refresh
# chain. If accounts.json ever refreshed, the two stores would fork the chain
# and break fleet auth. Empty refresh_token makes refresh-oauth-token /
# rotate-oauth fail closed on this account. This file MIRRORS, it never OWNS.
# Access tokens expire ~hourly: run this on an OS timer (not an LLM turn).
set -euo pipefail
CRED="$HOME/.claude/.credentials.json"
OUT_DIR="$HOME/.cortextos/default/state/oauth"
OUT="$OUT_DIR/accounts.json"
mkdir -p "$OUT_DIR"
python3 - "$CRED" "$OUT" << 'PY'
import json, sys, os, tempfile, datetime
cred_path, out_path = sys.argv[1], sys.argv[2]
c = json.load(open(cred_path))["claudeAiOauth"]
try:
    store = json.load(open(out_path))
except Exception:
    store = {"active": "max-primary", "accounts": {}}
prev = store.get("accounts", {}).get("max-primary", {})
store["active"] = "max-primary"
store["accounts"]["max-primary"] = {
    "label": "Claude Max (mirrored from ~/.claude/.credentials.json — do not refresh here)",
    "access_token": c["accessToken"],
    "refresh_token": "",
    "expires_at": c["expiresAt"],
    "last_refreshed": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "five_hour_utilization": prev.get("five_hour_utilization", 0.0),
    "seven_day_utilization": prev.get("seven_day_utilization", 0.0),
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out_path))
with os.fdopen(fd, "w") as f:
    json.dump(store, f, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, out_path)
print(f"synced: expires_at={c['expiresAt']} ({(c['expiresAt']/1000 - __import__('time').time())/60:.0f} min left)")
PY
