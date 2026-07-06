#!/usr/bin/env bash
# Post-deploy smoke test. Checks the parts that curl CAN verify:
#   1. Domain resolves through Cloudflare Access without hitting the
#      wildcard Access login redirect (the bypass app is working).
#   2. The Worker responds 200 with the challenge shell for an
#      unauthenticated request.
#   3. /__verify correctly rejects a bogus token (403), proving the
#      siteverify round-trip is wired up. A 200 here does NOT mean the site
#      is broken — handleVerify fails OPEN when Cloudflare's siteverify is
#      unreachable (see DECISIONS.md), so a 200-on-bogus-token means the
#      gate is running in a degraded fail-open state and siteverify itself
#      needs attention, not that the token was wrongly accepted.
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

echo "==> [1/3] Checking https://$DOMAIN/ does not redirect to Cloudflare Access"
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

echo "==> [2/3] Checking challenge shell is served"
if grep -q "cf-turnstile" /tmp/nervous-verify-body.html; then
  echo "    OK (cf-turnstile widget present)"
else
  echo "    FAIL: challenge markup not found in response body"
  fail=1
fi
rm -f /tmp/nervous-verify-body.html

echo "==> [3/3] Checking /__verify rejects a bogus token"
verify_code=$(curl -sS -A "$UA" -o /dev/null -w "%{http_code}" -X POST \
  "https://$DOMAIN/__verify" -H "content-type: application/json" -d '{"token":"bogus"}')
if [ "$verify_code" = "403" ]; then
  echo "    OK (403 as expected — siteverify reachable, bogus token rejected)"
elif [ "$verify_code" = "200" ]; then
  echo "    DEGRADED: got 200, not 403 — handleVerify's fail-open path engaged,"
  echo "    meaning Cloudflare's siteverify is unreachable/erroring right now."
  echo "    Real visitors are unaffected (they're being let through), but this"
  echo "    needs attention: check the Worker's Observability logs for the"
  echo "    'siteverify unreachable' / 'unexpected shape' log line."
  fail=1
else
  echo "    FAIL: expected 403 (or degraded 200), got $verify_code"
  fail=1
fi

echo
if [ "$fail" = "0" ]; then
  echo "All checks passed."
else
  echo "One or more checks FAILED — see above."
  exit 1
fi
