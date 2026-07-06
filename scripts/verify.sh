#!/usr/bin/env bash
# Post-deploy smoke test. Checks the parts that curl CAN verify:
#   1. Domain resolves through Cloudflare Access without hitting the
#      wildcard Access login redirect (the bypass app is working).
#   2. The Worker responds 200 with the challenge shell for an
#      unauthenticated request, AND serves the exact sitekey config/cloudflare.json
#      expects (catches sitekey drift between served widget and config).
#   3. GET /__health reports gate:ok — this is the ONLY automatable check that
#      can tell "our secret is wrong" apart from "everything's fine", because
#      an HTTP status on /__verify alone cannot: a wrong secret and a
#      transient Cloudflare blip both fail open there. See "Why /__health
#      exists" in DECISIONS.md — this is the check that would have caught the
#      2026-07-06 incident, where a bogus-token POST kept passing while real
#      visitors were rejected the whole time.
#   4. Sitekey+secret are one atomic pair, sourced from the SAME widget. This
#      is the strongest automatable defense against the residual gap /__health
#      cannot see: an individually-valid secret paired with the wrong widget's
#      sitekey looks identical to /__health as a healthy gate. Reads the
#      widget's live secret directly via the Cloudflare API and compares it to
#      bf's NERVOUS_TURNSTILE_SECRET_KEY.
#
# What this CANNOT check: a real human passing the invisible Turnstile
# challenge — that requires a genuine (non-headless) browser, since
# Turnstile is designed to refuse to resolve silently for automation. See
# docs/MAINTENANCE.md#testing-the-real-challenge.
#
# Usage: scripts/verify.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

DOMAIN=$(cfg "['custom_domain']")
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

fail=0

echo "==> [1/4] Checking https://$DOMAIN/ does not redirect to Cloudflare Access"
resp=$(curl -sS -A "$UA" -o /tmp/nervous-verify-body.html -w "%{http_code} %{redirect_url}" "https://$DOMAIN/")
code=$(echo "$resp" | awk '{print $1}')
redirect=$(echo "$resp" | awk '{print $2}')
if echo "$redirect" | grep -q "cloudflareaccess.com"; then
  echo "    FAIL: redirected to Cloudflare Access ($redirect)."
  echo "    Run scripts/setup-access-bypass.sh"
  fail=1
elif [ "$code" != "200" ]; then
  echo "    FAIL: expected 200, got $code"
  fail=1
else
  echo "    OK ($code, no Access redirect)"
fi

echo "==> [2/4] Checking challenge shell is served with the expected sitekey"
CONFIG_SITEKEY=$(cfg "['turnstile']['sitekey']")
if grep -q "data-sitekey=\"$CONFIG_SITEKEY\"" /tmp/nervous-verify-body.html; then
  echo "    OK (exact sitekey $CONFIG_SITEKEY present, matches config)"
elif grep -q "cf-turnstile" /tmp/nervous-verify-body.html; then
  echo "    FAIL: cf-turnstile widget present but sitekey doesn't match"
  echo "    config/cloudflare.json's $CONFIG_SITEKEY — sitekey drift."
  fail=1
else
  echo "    FAIL: challenge markup not found in response body"
  fail=1
fi
rm -f /tmp/nervous-verify-body.html

echo "==> [3/4] Checking GET /__health reports gate:ok"
# This is the discriminating check the 2026-07-06 incident lacked: a bogus
# token to /__verify passes identically whether TURNSTILE_SECRET_KEY is right
# or wrong, because Cloudflare rejects a malformed token either way. /__health
# instead probes with Cloudflare's own always-fails dummy token and reads the
# error-codes array, the one signal that can actually tell "wrong secret"
# apart from "correctly rejected a bad token."
health_json=$(curl -sS "https://$DOMAIN/__health" || echo '{"gate":"degraded","reason":"unreachable"}')
gate=$(echo "$health_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('gate','?'))" 2>/dev/null || echo "?")
reason=$(echo "$health_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reason','?'))" 2>/dev/null || echo "?")

if [ "$gate" = "ok" ]; then
  echo "    OK (gate:ok — TURNSTILE_SECRET_KEY is correct)"
elif [ "$reason" = "secret" ]; then
  echo "    FAIL: gate:degraded reason:secret — the deployed TURNSTILE_SECRET_KEY"
  echo "    is WRONG (Cloudflare's siteverify rejected it on the secret side)."
  echo "    Real visitors are being let through via fail-open right now, but"
  echo "    this needs fixing: re-run scripts/deploy.sh (it converges this on"
  echo "    every run), or see docs/MAINTENANCE.md if that doesn't clear it."
  fail=1
else
  echo "    DEGRADED: gate:$gate reason:$reason — siteverify itself is likely"
  echo "    unreachable/erroring right now (not a secret problem). Real"
  echo "    visitors are unaffected (fail-open), but worth checking again soon."
  fail=1
fi

echo "==> [4/4] Checking sitekey+secret are one atomic pair from the same widget"
ACCOUNT_ID=$(cfg "['account_id']")
LIVE_SECRET=$(curl -sS -H "Authorization: Bearer $(cf_token CF_TURNSTILE_TOKEN)" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/challenges/widgets/$CONFIG_SITEKEY" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('secret',''))" 2>/dev/null || echo "")
BF_SECRET=$(cf_token NERVOUS_TURNSTILE_SECRET_KEY 2>/dev/null || echo "")

if [ -z "$LIVE_SECRET" ]; then
  echo "    SKIP: couldn't read the widget's live secret (CF_TURNSTILE_TOKEN"
  echo "    issue?) — not treated as a failure, just unconfirmed."
elif [ "$LIVE_SECRET" = "$BF_SECRET" ]; then
  echo "    OK (bf's NERVOUS_TURNSTILE_SECRET_KEY matches sitekey $CONFIG_SITEKEY's live secret)"
else
  echo "    FAIL: bf's NERVOUS_TURNSTILE_SECRET_KEY does NOT match sitekey"
  echo "    $CONFIG_SITEKEY's actual live secret — they may individually look"
  echo "    valid (this is the one class of bug /__health cannot catch) but"
  echo "    belong to different widgets. Re-fetch the correct secret from the"
  echo "    widget config and update bf; see docs/MAINTENANCE.md."
  fail=1
fi

echo
if [ "$fail" = "0" ]; then
  echo "All checks passed."
else
  echo "One or more checks FAILED — see above."
  exit 1
fi
