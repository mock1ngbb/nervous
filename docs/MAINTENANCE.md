# Maintenance

## Secrets

Every Cloudflare API token used here is resolved on demand via `bf get <NAME>` —
none are stored in this repo, in `config/cloudflare.json`, or in any env file.
`config/cloudflare.json` only holds non-secret IDs (account ID, zone ID, sitekey,
worker names).

This account splits Cloudflare API access into **per-purpose tokens** rather than
one broad token. The exact scope each script needs, and why the "obvious" token
sometimes doesn't work:

| Token | Used for | Why not a different one |
|---|---|---|
| `CF_TURNSTILE_TOKEN` | Creating/reading the Turnstile widget | `CF_ADMIN_TOKEN` looked like it should work (it passes a broad account-scope probe) but returned `Authentication error [10000]` on the actual widget-create call. `CF_TURNSTILE_TOKEN` is the one actually scoped for `Account.Turnstile:Edit`. |
| `CF_WORKERS_TOKEN` | Deploying Worker scripts, setting Worker secrets | Scoped for `Account.Workers Scripts:Edit`. Does **not** cover the custom-domain route step (below). |
| `CF_ADMIN_TOKEN` | The `routes = [{ custom_domain = true }]` step in `wrangler deploy` | This needs `Zone.Workers Routes:Edit` on the `mock1ngbb.com` zone, which `CF_WORKERS_TOKEN` and `CF_WORKERS_DOMAINS_TOKEN` (despite the name) do not have in this account. `CF_ADMIN_TOKEN` does. |
| `CF_ZT_TOKEN` | Reading/creating Access apps (the bypass app) | Scoped for `Access: Organizations, Identity Providers, and Groups` + Access Apps. |

**If a step 403s or returns `Authentication error [10000]`**: don't assume the
token is missing or broken — this account's tokens are split narrowly by purpose,
and the fix is almost always "use the more specific token," not "get a new token."
Check `docs/MAINTENANCE.md#secrets` above before concluding anything is missing.

## Rotating `COOKIE_SECRET`

Rotating it immediately invalidates every visitor's current `ns_verified` cookie —
they'll just see the invisible challenge again on their next request, which is
harmless (it's invisible). Rotate with:

```bash
openssl rand -hex 32 | (cd worker && npx wrangler secret put COOKIE_SECRET --name nervous-system-states)
```

`scripts/deploy.sh` will never do this automatically once a secret already exists
— see [DEPLOY.md](DEPLOY.md).

## Rotating the Turnstile widget

Rotating the widget (creating a new one) changes both the sitekey and secret.
Don't do this casually — it means updating `config/cloudflare.json`,
`worker/src/index.js`'s `SITEKEY` constant, and re-setting
`TURNSTILE_SECRET_KEY` on the siteverify Worker, then redeploying both Workers.
`scripts/setup-turnstile.sh` refuses to run if a sitekey is already configured, as
a guard against accidentally doing this. To force a rotation, temporarily clear
`turnstile.sitekey` in `config/cloudflare.json`, run the script, then follow its
printed instructions.

## Testing the real challenge

`scripts/verify.sh` cannot verify that a real visitor successfully passes the
invisible challenge and gets a cookie — it can only prove `/__verify` correctly
*rejects* a bogus token. This isn't a gap in the script; it's inherent to how
Turnstile works: it's specifically designed to detect and refuse to resolve for
headless/automated browsers (confirmed while building this — a headless
Playwright WebKit session got stuck at the challenge shell indefinitely with only
Cloudflare's own `cf_clearance` cookie set, never the `ns_verified` one).

To actually confirm a human passes cleanly: open `https://nervous.mock1ngbb.com/`
in a real, non-headless browser and confirm the real page renders within a couple
seconds with no visible widget. `open -a Safari https://nervous.mock1ngbb.com/` on
macOS is the simplest way to do this by hand.

**Do not use Chrome/Chromium for manual checks on this machine** — the operator's
standing preference is Safari or Firefox (Chrome's RAM usage). If you need
automated (not just eyeballing) verification of static rendering — page layout,
CSS, non-Turnstile content — use Playwright's bundled **WebKit** engine
(`playwright.webkit`, not `chromium`), which needs no macOS screen-recording
permission and isn't Chrome. It will *not* pass the actual Turnstile challenge
(see above), but it's the right tool for everything else about the page.

## Known quirks

- **Workers Static Assets bypass the Worker's `fetch()` handler by default.**
  This is the single most important gotcha in this repo. With `[assets]`
  configured but no `run_worker_first = true`, Cloudflare serves any request
  path matching a file under `directory` (e.g. `/` → `site/index.html`)
  **directly from the edge**, without ever invoking `src/index.js`. During
  initial setup this meant the cookie/Turnstile gate was silently doing
  nothing — a cookie-less request got the full real page, no challenge, no
  `Set-Cookie`, none of this Worker's response headers. It was caught by
  adding a temporary `X-Debug-Branch` response header and noticing it never
  appeared on live requests, proving the Worker code wasn't running at all.
  `run_worker_first = true` in `worker/wrangler.toml`'s `[assets]` block is
  the fix — if it's ever removed "to simplify," the whole gate silently stops
  working while still returning 200s that *look* fine.
- **Even after the Worker runs, watch `Cache-Control` on served responses.**
  A verified (real-content) response returned with a shared-cacheable
  `Cache-Control` (which `env.ASSETS.fetch()` sets by default) can get cached
  at Cloudflare's edge and then served to *other, unrelated visitors*
  regardless of their own cookie — confirmed live: one authenticated fetch
  got cached, and every subsequent cookie-less `curl` got the real page
  straight from cache. Both response branches in `src/index.js` explicitly
  set `Cache-Control: private, no-store` for this reason. Don't remove it.
- **Cache purges by URL can silently no-op on this zone.** The default Free
  plan "Standard" cache level ignores query strings when computing the cache
  key, so bumping a `?cachebust=` query param does not force a fresh fetch,
  and a single-URL purge can also miss if the cached variant's key doesn't
  match exactly. `purge_cache` with `{"purge_everything": true}` is the
  reliable way to confirm a fix is actually live, not a leftover cached
  response.
- **`vendor/turnstile-siteverify`'s own `validate.sh` `/health` check can false-fail.**
  It greps for the literal substring `"ok":true`, but Cloudflare Workers'
  `Response.json()`-adjacent tooling sometimes pretty-prints as `"ok": true`
  (with a space). If `validate.sh` reports a health-check failure, check the
  endpoint by hand (`curl <worker-url>/health`) before assuming it's actually
  down — this is a vendored script, not something this repo should patch, since
  patching it would drift from upstream.
- **`security find-generic-password -s "bifrost-<NAME>"` can report "item not
  found" even when `bf get <NAME>` succeeds.** Always resolve secrets via `bf get`,
  not by guessing the raw keychain service name — `bf` handles whichever backend
  actually has the value.
- **A brand-new subdomain can get swept into Zero Trust before you've done
  anything.** If a fresh domain immediately redirects to
  `*.cloudflareaccess.com` on first request, check for a wildcard Access app on
  the account before assuming something in this repo is misconfigured — see
  [DECISIONS.md](DECISIONS.md).
