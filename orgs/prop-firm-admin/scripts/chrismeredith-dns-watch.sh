#!/usr/bin/env bash
# chrismeredith-dns-watch.sh — is chrismeredith.us resolving to Bluehost AND serving the real site?
#
# WHY THIS EXISTS
# ---------------
# 2026-08-11: the domain was mid-migration. DNS returned THREE different answers in half an hour
# (162.241.225.12, 66.235.200.147, 74.220.199.6). The server side is finished and correct; only
# propagation is outstanding. This answers the one question worth asking: can a real visitor
# reach Chris's site right now?
#
# TWO QUESTIONS, BOTH PRINTED — never collapse them into one "OK".
#   1. RESOLVES  — does DNS point at Bluehost?
#   2. SERVES    — does that address actually return the site (not a challenge page)?
# A domain can resolve correctly and still serve the wrong thing. Reporting only (1) is the
# liveness-is-not-function trap: see reference_liveness_is_not_function.
#
# The content probe is what makes this fail-closed: HTTP 200 is NOT enough, because the old host
# answers 200 with a Cloudflare "Just a moment..." interstitial. We require a string that only
# Chris's page contains.
#
# Exit: 0 = LANDED (resolves to Bluehost and serves the real page). 1 = not yet. 2 = broken probe.

set -uo pipefail

DOMAIN=chrismeredith.us
BLUEHOST_IP=162.241.225.12
MARKER='Amazonian Operator'          # appears only on the real page
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'

# ── 1. RESOLVES? ask two public resolvers, not the local cache ───────────────
IPS=$(python3 - "$DOMAIN" <<'PY'
import json,sys,urllib.request
dom=sys.argv[1]; out=[]
for u in (f'https://dns.google/resolve?name={dom}&type=A',
          f'https://cloudflare-dns.com/dns-query?name={dom}&type=A'):
    try:
        r=urllib.request.Request(u,headers={'Accept':'application/dns-json'})
        d=json.load(urllib.request.urlopen(r,timeout=15))
        out += [a.get('data') for a in d.get('Answer',[]) if a.get('type')==1]
    except Exception:
        pass
print(' '.join(sorted(set(filter(None,out)))))
PY
)
if [ -z "$IPS" ]; then
  echo "dns-watch: PROBE BROKEN — no resolver answered. Not a verdict about the domain."
  exit 2
fi
echo "dns-watch: $DOMAIN resolves to: $IPS"

RESOLVES=0
for ip in $IPS; do [ "$ip" = "$BLUEHOST_IP" ] && RESOLVES=1; done

# ── 2. SERVES? fetch through REAL DNS and require the marker ─────────────────
BODY=$(curl -s --compressed -m 25 -A "$UA" -H 'Accept: text/html' "https://$DOMAIN/" 2>/dev/null)
CODE=$(curl -s -o /dev/null -m 25 -A "$UA" -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null)
SERVES=0
case "$BODY" in *"$MARKER"*) SERVES=1 ;; esac

echo "dns-watch: http=$CODE  real-page-marker=$([ $SERVES -eq 1 ] && echo present || echo ABSENT)"

# Control: the server itself must still be serving correctly, bypassing DNS. If this fails the
# problem is NOT propagation and the whole report is suspect.
CTRL=$(curl -s --compressed -m 25 -A "$UA" --resolve "$DOMAIN:443:$BLUEHOST_IP" "https://$DOMAIN/" 2>/dev/null)
case "$CTRL" in
  *"$MARKER"*) echo "dns-watch: control OK — Bluehost serves the real page when addressed directly" ;;
  *) echo "dns-watch: ⚠ CONTROL FAILED — Bluehost is NOT serving the page. This is a SERVER problem, not DNS."; exit 2 ;;
esac

if [ $RESOLVES -eq 1 ] && [ $SERVES -eq 1 ]; then
  echo "dns-watch: ✅ LANDED — resolves to Bluehost and serves the real site."
  exit 0
fi

# ── Distinguish "still moving" from "landed somewhere broken" ────────────────
# 2026-08-11: mid-cutover DNS briefly returned 74.220.199.6, which answers
# NOTHING (curl exit 000) — neither the old host nor the live one. That is fine
# while the old host is still in the rotation, because traffic still resolves
# somewhere that answers. It stops being fine the moment the old host drops out
# and the only remaining address does not serve: the cutover has then COMPLETED
# onto a dead IP, and this watch would otherwise report "still propagating"
# forever while the domain is actually down.
OLD_HOST=66.235.200.147
still_has_old=0
serves_anything=0
for ip in $IPS; do
  [ "$ip" = "$OLD_HOST" ] && still_has_old=1
  code=$(curl -s -o /dev/null -m 15 -A "$UA" --resolve "$DOMAIN:443:$ip" -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null)
  [ "$code" != "000" ] && serves_anything=1
done
if [ $still_has_old -eq 0 ] && [ $serves_anything -eq 0 ]; then
  echo "dns-watch: ⚠ LANDED ON A NON-RESPONDING ADDRESS — old host is gone from DNS and no resolved IP answers at all."
  echo "dns-watch:   resolved: $IPS   expected Bluehost: $BLUEHOST_IP"
  echo "dns-watch:   This is NOT propagation latency. The domain is effectively down for anyone whose DNS has updated."
  exit 2
fi

echo "dns-watch: ⏳ not yet (resolves_to_bluehost=$RESOLVES serves_real_page=$SERVES). Still propagating; no action."
exit 1
