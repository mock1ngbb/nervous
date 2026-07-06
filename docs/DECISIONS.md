# Decisions — why this, not the obvious alternative

This doc covers the infrastructure choices only. For why this page exists at all,
see the [README](../README.md#why-this-exists).

## Why Turnstile "Invisible" mode, not "Managed" or "Non-Interactive"

Asked for research (`fedelm`) on this specifically. Cloudflare's three modes:

- **Managed** — auto-picks between a checkbox and a background challenge based on
  visitor risk. Can interrupt a real visitor with a checkbox.
- **Non-Interactive** — always shows a widget with a spinner, never requires a
  click, but the spinner is visible.
- **Invisible** — no widget, no spinner, no visible UI at all. Resolves entirely in
  the background.

The ask was explicitly "non-intrusive," and this is a static content page, not a
login/signup form where friction is more tolerable. Invisible mode is the only one
of the three with zero visible footprint, so it's the one used here.

## Why not just add this to Cloudflare Access with a Turnstile policy?

The account already has this pattern elsewhere — e.g. `rift-root.mock1ngbb.com`,
`msi.mock1ngbb.com`, and `bifrost-demo.mock1ngbb.com` are set up as Access
applications whose policy requires passing a Turnstile check instead of an identity
check. It's a legitimate pattern, and it would have been less code (no custom
Worker gate logic needed).

It wasn't used here because the operator explicitly said **no Cloudflare Access /
Zero Trust** for this one. Even a Turnstile-only Access policy is still an Access
application under the hood — same product, same infrastructure, same dashboard
surface as identity-gated apps. So instead this is a from-scratch Worker that does
its own Turnstile verification and its own session cookie, with zero involvement
from Access as an authorization layer.

## Why an Access app exists anyway, if the goal was "no Zero Trust"

This account has a **wildcard `*.mock1ngbb.com` Access application** that, by
default, puts every subdomain under Access identity login — including brand new
ones like `nervous.mock1ngbb.com`, which got swept in automatically the moment DNS
existed for it. This wasn't something we opted into; it's a pre-existing
account-wide default that had to be opted *out* of.

The account already has a standard pattern for opting a domain out of that
wildcard: a small Access app scoped to just that domain, with a single policy —
`decision: bypass`, `include: everyone`. Several other public pages in this account
use exactly this (`www.mock1ngbb.com public bypass`, `lfs-bridge public bypass`,
`riftroot-qa public bypass`, etc.). `scripts/setup-access-bypass.sh` creates the
same shape of app for `nervous.mock1ngbb.com`.

This app does not gate anything — its only effect is to cancel out the wildcard
app's gate. Net effect: zero Access/Zero Trust involvement in whether a visitor can
reach the page. All actual bot-filtering is the Turnstile widget + Worker logic
described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Why Workers Static Assets instead of inlining the HTML in the Worker script

The first working deploy (done live, before this repo existed) inlined the entire
page as an escaped JavaScript template literal inside the Worker script, generated
by a one-off Python script. It worked, but every content edit meant re-running an
escaping step and re-generating a giant string literal — fragile and unpleasant to
diff in git.

This repo uses `[assets]` in `wrangler.toml` instead: `site/index.html` is a normal
static file, served via the `ASSETS` binding
(`env.ASSETS.fetch(request)`) when the visitor is verified. Content edits are now
just editing HTML. The Worker script only owns the challenge/cookie logic.

## Why a hand-rolled HMAC cookie instead of KV-backed sessions

VeilGate (this account's other auth gateway, for `portal.mock1ngbb.com` and
protected internal tools) uses KV-backed sessions with revocation, email
whitelisting, and magic-link OTP. That's the right tool for gating access to
internal tools by identity.

This page needs none of that — there's no identity, no revocation requirement, no
per-user state. A signed, self-expiring cookie (HMAC-SHA256 over a timestamp) is
enough: it can't be forged without `COOKIE_SECRET`, and it naturally stops being
valid after 12 hours without needing a cleanup job or a KV read on every request.

## Why the siteverify Worker is vendored here instead of just linking to it

`vendor/turnstile-siteverify/` is a copy of
[Cloudflare's own turnstile-spin template](https://developers.cloudflare.com/turnstile/spin/),
fetched via `degit` at setup time. It's committed here (not just referenced) so
that this repo can fully reproduce its own infrastructure without depending on that
skill/template still being fetchable in exactly this shape later. If Cloudflare
changes the template, this repo's copy won't drift out from under it.

## Why we no longer run a separate siteverify Worker

Originally `worker/src/index.js` POSTed tokens to a deployed copy of
`vendor/turnstile-siteverify` (a second, independently-deployed Worker,
`turnstile-siteverify-nervous`) rather than calling Cloudflare's
`https://challenges.cloudflare.com/turnstile/v0/siteverify` endpoint directly.

That sidecar Worker was deleted from the Cloudflare account on 2026-07-03
(confirmed via the account's audit log: a `script_delete` action against
`turnstile-siteverify-nervous`, actor the operator's own account, most likely an
unrelated stale-Worker cleanup pass that had no way to know this Worker was still
a live runtime dependency of `nervous-system-states` — nothing in either repo
declared that cross-Worker dependency anywhere Cloudflare or a cleanup tool could
see it). The main Worker kept routing fine (it doesn't depend on the sidecar for
anything except the one `/__verify` call), so the failure was invisible until a
real visitor tried to pass the invisible challenge: their token POST to
`/__verify` hit the now-missing sidecar, got Cloudflare's edge HTML error page
back instead of JSON, and the unguarded `.json()` call threw — a bare 500, no
cookie ever set, the visitor stuck forever on the invisible-widget page (which
looks like "the page doesn't load" even though `/` itself still returns 200).

The sidecar added an independent deployable that could vanish on its own, plus a
network hop, for zero actual benefit — the only caller was this Worker, sending a
plain `{token}` JSON body; none of the template's other features (reCAPTCHA
compatibility, form-encoded parsing, its own CORS/observability) were ever
exercised in this single-caller setup. So the fix collapses siteverify into the
main Worker: `handleVerify()` now POSTs directly to Cloudflare's own siteverify
endpoint with the widget secret as `env.TURNSTILE_SECRET_KEY`, held as a secret on
`nervous-system-states` itself. `vendor/turnstile-siteverify/` stays in the repo as
reference/documentation of the sidecar template — it's just no longer part of the
runtime path. If the sidecar's `wrangler.toml` is ever redeployed by hand, note it
still says `name = "turnstile-siteverify"` (the upstream template default) while
the account's copy was created via `wrangler deploy --name
turnstile-siteverify-nervous`; a bare `wrangler deploy` in that directory creates a
*third*, differently-named Worker rather than touching the (now-decommissioned)
one — a confusing trap if anyone ever revives it.

## Why `handleVerify` fails open when siteverify is unreachable

`handleVerify()` treats Cloudflare's siteverify call as three distinct outcomes,
not a single try/catch around everything:

- **Reachable + `success: true`** → set the cookie, 200 (the normal path).
- **Reachable + `success: false`** → 403. This is a genuine signal — the token was
  bad, expired, or reused — and must stay fail-**closed**.
- **Unreachable, non-2xx, or a response that doesn't parse as the expected
  shape** → fail **open**: set the cookie and return 200, after logging the
  failure distinctly via `console.error` (see the Observability note below).

This is a deliberate, operator-ratified security tradeoff, not a default. The
reasoning: by the time a token reaches `/__verify`, the visitor's browser has
already resolved the invisible Turnstile challenge — fail-open means "trust the
token the widget already vetted, since we can't double-check it right now," not
"let anyone in." This page has near-zero bot-abuse value (it's a personal
reference page, not a form, login, or paid resource), so a temporarily-weakened
gate during a Cloudflare-side or network blip is a much smaller cost than
repeating the exact incident this replaces: a downstream failure silently
stranding a real human on a black screen forever, with zero server-side signal.

## Why Workers Observability is enabled on the main Worker

Before this incident, `worker/wrangler.toml` had no `[observability]` block, so
the 500s from the missing sidecar left no queryable trace anywhere — the outage
was only detectable by hitting the site by hand and reading a raw Cloudflare edge
error page. `[observability]\nenabled = true` makes the `console.error` calls in
`handleVerify()` (both the fail-open path and any unexpected-shape response)
show up in the Worker's Observability tab, so a future degraded-gate window is
discoverable by looking, not just by a stranded visitor reporting it.
