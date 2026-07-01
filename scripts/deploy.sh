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
echo "==> Done. Verify with: scripts/verify.sh"
