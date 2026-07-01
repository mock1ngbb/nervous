# Deploy

## Prerequisites

- `wrangler` (installed on demand via `npx wrangler`, no global install needed)
- `bf` (Bifrost secrets CLI) on `PATH`, able to resolve `CF_TURNSTILE_TOKEN`,
  `CF_WORKERS_TOKEN`, `CF_ADMIN_TOKEN`, `CF_ZT_TOKEN` — see
  [MAINTENANCE.md#secrets](MAINTENANCE.md#secrets) for what each is scoped to
- Python 3 (used by the scripts for JSON handling — no extra packages needed)

## Fresh setup (new domain / rebuilding from scratch)

Run in this order — each step depends on the previous one's output:

```bash
scripts/setup-turnstile.sh
```
Creates the Turnstile widget (invisible mode) and deploys the vendored siteverify
Worker. Prints the new sitekey. **Manually** update `config/cloudflare.json`'s
`turnstile.sitekey` and `worker/src/index.js`'s `SITEKEY` constant to match — this
step is intentionally not auto-applied, so a config change is always a visible git
diff, not a side effect of running a script.

```bash
scripts/setup-access-bypass.sh
```
Exempts the domain from the account's wildcard Cloudflare Access app. Safe to
re-run — checks for an existing app on the domain first.

```bash
scripts/deploy.sh
```
Deploys `nervous-system-states`. On a truly fresh Worker, also generates and sets
`COOKIE_SECRET` (only if it detects the secret doesn't already exist — never
overwrites one that's already set, since that would invalidate every current
visitor's session).

```bash
scripts/verify.sh
```
Runs the three checks that curl alone can verify: no Access redirect, challenge
shell served, `/__verify` correctly rejects a bogus token. See
[MAINTENANCE.md#testing-the-real-challenge](MAINTENANCE.md#testing-the-real-challenge)
for why a full pass-the-challenge test needs a real (non-headless) browser.

## Routine redeploy (content or logic change)

```bash
$EDITOR site/index.html              # content changes
$EDITOR worker/src/index.js          # gate logic changes
$EDITOR worker/src/challenge.html    # challenge shell changes
scripts/deploy.sh
scripts/verify.sh
```

No need to touch the Turnstile widget or the Access bypass app for ordinary content
edits — those are one-time setup steps.
