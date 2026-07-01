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
