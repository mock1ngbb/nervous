#!/usr/bin/env bash
# Shared helpers for scripts/*.sh. Source this, don't run it directly.
#
# All Cloudflare tokens are pulled on demand via `bf` (Bifrost secrets) —
# see docs/MAINTENANCE.md#secrets for which token is used where and why.

set -euo pipefail

CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/cloudflare.json"

cfg() {
  python3 -c "import json,sys; d=json.load(open('$CONFIG_FILE')); print(d$1)"
}

require_bf() {
  if ! command -v bf >/dev/null 2>&1; then
    echo "ERROR: 'bf' (Bifrost secrets CLI) not found on PATH. See ~/CLAUDE.md for setup." >&2
    exit 1
  fi
}

# cf_token <SECRET_NAME> — resolve a Cloudflare API token via bf.
# Never echoes to a log; caller should keep it in a local var, not export
# it where it could leak into child-process argv (curl -H is fine; argv
# params are not).
cf_token() {
  require_bf
  bf get "$1"
}

# secret_state <worker-dir> <worker-name> <secret-name> -> present|absent|indeterminate
# `wrangler secret list` failing (network blip, malformed JSON, auth hiccup)
# must NEVER be treated as "absent" — that would make a transient error
# silently trigger regeneration of a secret that's actually fine and still
# live (e.g. COOKIE_SECRET), invalidating every visitor's session for no
# reason. Callers must abort on "indeterminate", not fall through to heal.
secret_state() {
  local worker_dir="$1" worker_name="$2" secret_name="$3"
  local raw
  if raw=$(cd "$worker_dir" && npx wrangler secret list --name "$worker_name" 2>/dev/null); then
    echo "$raw" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('indeterminate')
    sys.exit()
name = sys.argv[1]
print('present' if any(s.get('name') == name for s in d) else 'absent')
" "$secret_name"
  else
    echo "indeterminate"
  fi
}
