#!/usr/bin/env bash
# One-time setup: create the Turnstile widget + deploy the siteverify Worker.
# Idempotent-ish: exits early with the existing sitekey if config/cloudflare.json
# already has one — this script does NOT rotate widgets. To rotate, see
# docs/MAINTENANCE.md#rotating-the-turnstile-widget.
#
# Usage: scripts/setup-turnstile.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

EXISTING_SITEKEY=$(cfg "['turnstile']['sitekey']" 2>/dev/null || echo "")
if [ -n "$EXISTING_SITEKEY" ] && [ "$EXISTING_SITEKEY" != "None" ]; then
  echo "config/cloudflare.json already has a sitekey ($EXISTING_SITEKEY)."
  echo "This script only creates a NEW widget. To rotate, see docs/MAINTENANCE.md."
  exit 0
fi

ACCOUNT_ID=$(cfg "['account_id']")
DOMAINS=$(cfg "['turnstile']['domains']" | python3 -c "import sys,ast; print(','.join(ast.literal_eval(sys.stdin.read())))" 2>/dev/null || echo "")
if [ -z "$DOMAINS" ]; then
  DOMAINS=$(cfg "['custom_domain']"),localhost,127.0.0.1
fi
WIDGET_NAME=$(cfg "['turnstile']['widget_name']")

# Widget creation needs Account.Turnstile:Edit — the dedicated CF_TURNSTILE_TOKEN,
# not CF_ADMIN_TOKEN or CF_WORKERS_TOKEN (both lack this scope in this account's
# per-purpose token split; see docs/MAINTENANCE.md#secrets).
export CLOUDFLARE_API_TOKEN="$(cf_token CF_TURNSTILE_TOKEN)"

echo "==> Creating Turnstile widget '$WIDGET_NAME' (mode=invisible, domains=$DOMAINS)"
body=$(curl -sS -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/challenges/widgets" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$WIDGET_NAME\",\"domains\":[$(echo "$DOMAINS" | sed 's/[^,]*/"&"/g')],\"mode\":\"invisible\"}")

success=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success'))")
if [ "$success" != "True" ]; then
  echo "ERROR: widget creation failed:" >&2
  echo "$body" >&2
  exit 1
fi

sitekey=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['sitekey'])")
secret=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['secret'])")
echo "==> Widget created. Sitekey: $sitekey"
echo "    (widget secret is NOT printed or stored on disk — pipe it straight into"
echo "    the siteverify Worker's TURNSTILE_SECRET_KEY secret, see below)"

echo
echo "==> Deploying siteverify Worker (vendor/turnstile-siteverify)"
SITEVERIFY_NAME=$(cfg "['siteverify_worker']['name']")
export CLOUDFLARE_API_TOKEN="$(cf_token CF_WORKERS_TOKEN)"
(cd vendor/turnstile-siteverify && npx wrangler deploy --name "$SITEVERIFY_NAME")
echo "$secret" | (cd vendor/turnstile-siteverify && npx wrangler secret put TURNSTILE_SECRET_KEY --name "$SITEVERIFY_NAME")

echo
echo "==> Update config/cloudflare.json manually with:"
echo "    turnstile.sitekey = \"$sitekey\""
echo "    (secret is never written to disk or committed — it now lives only as"
echo "    the siteverify Worker's TURNSTILE_SECRET_KEY secret)"
echo
echo "==> Then update worker/src/index.js's SITEKEY constant to match, and run"
echo "    scripts/deploy.sh"
