#!/usr/bin/env bash
# Deploys (or redeploys) the nervous-system-states Worker: main site content +
# the invisible-Turnstile gate. Idempotent — safe to re-run after editing
# site/index.html or worker/src/*.
#
# Does NOT touch the Turnstile widget or the Access bypass app — those are
# one-time setup steps (see setup-turnstile.sh, setup-access-bypass.sh) that
# rarely need to change. This script only redeploys the Worker itself.
#
# Usage: scripts/deploy.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

WORKER_NAME=$(cfg "['worker_name']")
ACCOUNT_ID=$(cfg "['account_id']")

echo "==> Deploying worker '$WORKER_NAME' (account $ACCOUNT_ID)"
export CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID"

# The custom-domain route (routes = [{ pattern = ..., custom_domain = true }])
# needs Zone:Workers Routes:Edit, which only CF_ADMIN_TOKEN carries in this
# account's token split. CF_WORKERS_TOKEN is enough for script upload alone
# but 403s on the route step. See docs/MAINTENANCE.md#secrets.
export CLOUDFLARE_API_TOKEN="$(cf_token CF_ADMIN_TOKEN)"

(cd worker && npx wrangler deploy)

echo
echo "==> Checking COOKIE_SECRET"
export CLOUDFLARE_API_TOKEN="$(cf_token CF_WORKERS_TOKEN)"
has_secret=$(cd worker && npx wrangler secret list --name "$WORKER_NAME" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if any(s['name']=='COOKIE_SECRET' for s in d) else 'no')" 2>/dev/null || echo "no")

if [ "$has_secret" = "yes" ]; then
  echo "    COOKIE_SECRET already set — leaving it alone (rotating it would"
  echo "    invalidate every visitor's session cookie; see MAINTENANCE.md)."
else
  echo "    COOKIE_SECRET missing — generating and setting one now."
  (cd worker && openssl rand -hex 32 | npx wrangler secret put COOKIE_SECRET --name "$WORKER_NAME")
fi

echo
echo "==> Checking TURNSTILE_SECRET_KEY"
# The Worker calls Cloudflare's siteverify endpoint directly (see
# DECISIONS.md) and needs its own copy of the Turnstile widget secret. Unlike
# COOKIE_SECRET, this can't be freshly generated — it's re-sourced from `bf`
# under NERVOUS_TURNSTILE_SECRET_KEY (NOT the generic `TURNSTILE_SECRET_KEY`
# name — bf/BIFROST_KV is a flat, non-namespaced store, and the generic name
# was already claimed by a shared/unrelated widget used by other projects on
# this account. Confirmed live 2026-07-06: `bf get TURNSTILE_SECRET_KEY`
# silently returned that OTHER widget's secret, real visitors got a clean 403
# from a healthy-looking pipeline, and the only way to catch it was a human
# testing in a real, non-automated browser — see docs/MAINTENANCE.md. Using
# a project-prefixed key name here is what actually prevents recurrence, not
# just documenting the risk). If a future deploy target is missing the
# secret, this heals it the same idempotent way COOKIE_SECRET heals above.
has_ts_secret=$(cd worker && npx wrangler secret list --name "$WORKER_NAME" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if any(s['name']=='TURNSTILE_SECRET_KEY' for s in d) else 'no')" 2>/dev/null || echo "no")

if [ "$has_ts_secret" = "yes" ]; then
  echo "    TURNSTILE_SECRET_KEY already set — leaving it alone."
else
  echo "    TURNSTILE_SECRET_KEY missing — re-sourcing from bf and setting it now."
  cf_token NERVOUS_TURNSTILE_SECRET_KEY | (cd worker && npx wrangler secret put TURNSTILE_SECRET_KEY --name "$WORKER_NAME")
fi

echo
echo "==> Done. Verify with: scripts/verify.sh"
