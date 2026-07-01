#!/usr/bin/env bash
# One-time setup: exempt the custom domain from this account's wildcard
# *.mock1ngbb.com Cloudflare Access application.
#
# IMPORTANT: this does NOT add Zero Trust / identity gating to the site.
# It does the opposite — it's a "public bypass" Access app (single policy,
# decision=bypass, include=everyone) whose only effect is to stop the
# account-wide wildcard Access app from intercepting this hostname. See
# docs/DECISIONS.md#why-an-access-app-when-the-goal-is-no-zero-trust.
#
# Idempotent: checks for an existing app with this domain first.
#
# Usage: scripts/setup-access-bypass.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

ACCOUNT_ID=$(cfg "['account_id']")
DOMAIN=$(cfg "['custom_domain']")
APP_NAME=$(cfg "['access_bypass_app']['name']")

export CLOUDFLARE_API_TOKEN="$(cf_token CF_ZT_TOKEN)"

echo "==> Checking for an existing Access app on $DOMAIN"
existing=$(curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps?per_page=200" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
match = [a for a in d['result'] if a.get('domain') == '$DOMAIN']
print(match[0]['id'] if match else '')
")

if [ -n "$existing" ]; then
  echo "    Found existing app ($existing) for $DOMAIN — nothing to do."
  echo "    If you need to verify its policy is still 'bypass', check:"
  echo "    curl -H \"Authorization: Bearer \$(bf get CF_ZT_TOKEN)\" \\"
  echo "      https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps/$existing"
  exit 0
fi

echo "==> Creating bypass app '$APP_NAME'"
curl -sS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "content-type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/apps" \
  -d "{
    \"name\": \"$APP_NAME\",
    \"type\": \"self_hosted\",
    \"domain\": \"$DOMAIN\",
    \"session_duration\": \"32h\",
    \"app_launcher_visible\": false,
    \"auto_redirect_to_identity\": false,
    \"policies\": [
      {
        \"name\": \"public bypass\",
        \"decision\": \"bypass\",
        \"include\": [{\"everyone\": {}}]
      }
    ]
  }" | python3 -m json.tool

echo
echo "==> Done. Propagation is usually a few seconds; if $DOMAIN still 302s to"
echo "    *.cloudflareaccess.com, wait ~10s and retry."
