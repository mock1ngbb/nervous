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
DOMAIN=$(cfg "['custom_domain']")

echo "==> Checking sitekey isn't drifted between code and config"
# SITEKEY is hand-duplicated in worker/src/index.js and config/cloudflare.json
# (challenge.html is templated from the former at build time). No build step
# exists to enforce these match, so a cheap pre-deploy string compare is the
# guard against ever shipping a widget/sitekey mismatch.
CODE_SITEKEY=$(grep -o 'SITEKEY = "[^"]*"' worker/src/index.js | head -1 | sed 's/SITEKEY = "\(.*\)"/\1/')
CONFIG_SITEKEY=$(cfg "['turnstile']['sitekey']")
if [ "$CODE_SITEKEY" != "$CONFIG_SITEKEY" ]; then
  echo "ERROR: sitekey drift — worker/src/index.js has '$CODE_SITEKEY' but" >&2
  echo "       config/cloudflare.json has '$CONFIG_SITEKEY'. Aborting rather" >&2
  echo "       than deploy a mismatched widget/sitekey pair." >&2
  exit 1
fi
echo "    OK ($CODE_SITEKEY matches in both places)"

echo
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
cookie_state=$(secret_state worker "$WORKER_NAME" COOKIE_SECRET)

case "$cookie_state" in
  present)
    echo "    COOKIE_SECRET already set — leaving it alone (rotating it would"
    echo "    invalidate every visitor's session cookie; see MAINTENANCE.md)."
    ;;
  absent)
    echo "    COOKIE_SECRET missing — generating and setting one now."
    (cd worker && openssl rand -hex 32 | npx wrangler secret put COOKIE_SECRET --name "$WORKER_NAME")
    ;;
  indeterminate)
    echo "ERROR: could not determine whether COOKIE_SECRET is set (wrangler" >&2
    echo "       secret list failed/returned something unparseable). Aborting" >&2
    echo "       rather than risk generating a new one and invalidating every" >&2
    echo "       visitor's session on what might just be a transient blip." >&2
    exit 1
    ;;
esac

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
# testing in a real, non-automated browser — see docs/MAINTENANCE.md).
ts_state=$(secret_state worker "$WORKER_NAME" TURNSTILE_SECRET_KEY)

case "$ts_state" in
  present)
    echo "    TURNSTILE_SECRET_KEY is set — will still verify it's CORRECT via"
    echo "    /__health below (present-but-wrong is exactly what caused the"
    echo "    2026-07-06 incident, and 'present' alone doesn't rule that out)."
    ;;
  absent)
    echo "    TURNSTILE_SECRET_KEY missing — re-sourcing from bf and setting it now."
    cf_token NERVOUS_TURNSTILE_SECRET_KEY | (cd worker && npx wrangler secret put TURNSTILE_SECRET_KEY --name "$WORKER_NAME")
    ;;
  indeterminate)
    echo "ERROR: could not determine whether TURNSTILE_SECRET_KEY is set." >&2
    echo "       Aborting rather than guess." >&2
    exit 1
    ;;
esac

echo
echo "==> Converging TURNSTILE_SECRET_KEY to CORRECT via /__health"
# /__health is the one endpoint that can tell "wrong secret" apart from
# "everything's fine" or "Cloudflare's briefly unreachable" (see
# worker/src/index.js). Only re-PUT the secret on a persistent reason:secret
# signal — never on reason:unreachable, so a transient blip can't cause
# secret churn. Re-PUTting the same correct namespaced value is idempotent.
health_check_url="https://$DOMAIN/__health"
attempt=1
max_attempts=3
while [ "$attempt" -le "$max_attempts" ]; do
  health_json=$(curl -sS "$health_check_url" || echo '{"gate":"degraded","reason":"unreachable"}')
  gate=$(echo "$health_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('gate','?'))" 2>/dev/null || echo "?")
  reason=$(echo "$health_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reason','?'))" 2>/dev/null || echo "?")

  if [ "$gate" = "ok" ]; then
    echo "    OK (attempt $attempt/$max_attempts: /__health reports gate:ok)"
    break
  elif [ "$reason" = "secret" ]; then
    echo "    /__health reports reason:secret (attempt $attempt/$max_attempts) —"
    echo "    re-setting TURNSTILE_SECRET_KEY from bf and re-checking."
    cf_token NERVOUS_TURNSTILE_SECRET_KEY | (cd worker && npx wrangler secret put TURNSTILE_SECRET_KEY --name "$WORKER_NAME")
    sleep 3
  else
    echo "    /__health reports gate:$gate reason:$reason (attempt $attempt/$max_attempts) —"
    echo "    likely transient; not touching the secret, retrying."
    sleep 3
  fi
  attempt=$((attempt + 1))
done

if [ "$gate" != "ok" ]; then
  echo "WARNING: /__health still not reporting gate:ok after $max_attempts" >&2
  echo "         attempts (last: gate:$gate reason:$reason). If reason is" >&2
  echo "         'secret', the value in bf's NERVOUS_TURNSTILE_SECRET_KEY may" >&2
  echo "         itself be wrong — verify it against the widget's live config" >&2
  echo "         (see docs/MAINTENANCE.md) rather than re-running this script" >&2
  echo "         in a loop." >&2
fi

echo
echo "==> Done. Verify with: scripts/verify.sh"
