# Decisions — why this, not the obvious alternative

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
