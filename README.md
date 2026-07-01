# nervous

A resource I built while learning to actually notice what my body is doing —
nervous system regulation, interoception, the practice of paying attention to the
signal underneath the story about the signal. Authenticity is my highest value
and, I'd say, my nature — everything else I value derives from it, not the other
way around. In practice that means the moment my nervous system flags a gap
between what's *lived* and what's *spoken* — mine or someone else's — is
information, not noise. This page ([site/index.html](site/index.html)) is the map
I made of that terrain: sympathetic states, the window of tolerance, dorsal vagal
shutdown, the narrative layer each state gets tagged with, and the ways they route
into each other depending on which story shows up.

It's served from a Cloudflare Worker at **nervous.mock1ngbb.com**, sitting behind
an **invisible** Cloudflare Turnstile bot-check. No visible CAPTCHA, no login, no
Cloudflare Access/Zero Trust identity gate. Just the content, protected quietly —
which felt like the right shape for something this personal: available, not
performative, not gated behind a login wall that would turn "here's what I
learned" into "here's a product."

This repo is both the content and every tool used to build, deploy, and maintain it.

## Layout

```
site/index.html               the actual page (edit this to change content)
worker/                        the Cloudflare Worker that serves it
  wrangler.toml
  src/index.js                 gate logic: challenge vs. real content
  src/challenge.html            the invisible-widget challenge shell
vendor/turnstile-siteverify/   vendored copy of Cloudflare's siteverify Worker template
                                (deployed separately; verifies Turnstile tokens server-side)
config/cloudflare.json         non-secret IDs (account, zone, sitekey, worker names)
scripts/                       every command used to stand this up, made idempotent
docs/
  ARCHITECTURE.md               how a request flows through this, end to end
  DECISIONS.md                  why it's built this way, not the obvious alternatives
  DEPLOY.md                     step-by-step: fresh setup vs. routine redeploy
  MAINTENANCE.md                secrets, rotation, troubleshooting, known quirks
```

## Quick start

```bash
# Fresh setup (only once, or after a full teardown):
scripts/setup-turnstile.sh        # widget + siteverify Worker
scripts/setup-access-bypass.sh    # exempt the domain from the account's wildcard Access app
scripts/deploy.sh                 # deploy the Worker itself
scripts/verify.sh                 # smoke test

# Routine content/logic update:
$EDITOR site/index.html           # or worker/src/index.js, worker/src/challenge.html
scripts/deploy.sh
scripts/verify.sh
```

All Cloudflare API tokens are resolved on demand via `bf` (Bifrost secrets) — nothing
is stored on disk or in this repo. See [docs/MAINTENANCE.md](docs/MAINTENANCE.md) for
which token does what.

## Why this exists

**The content:** tracking nervous system states is part of how I get back to
myself when the gap between what I'm saying and what I'm actually feeling gets
wide enough to notice. The chart in `site/index.html` is what came out of doing
that tracking long enough to see the shape of it — what each state actually feels
like in the body, what narrative it tends to generate, and where it can go next
depending on which story takes hold. It's a working reference, not a finished
theory.

**The delivery:** for the infrastructure reasoning — why invisible Turnstile
instead of a visible CAPTCHA, why a from-scratch Worker instead of folding this
into the account's existing Cloudflare Access setup — see the full writeup in
[docs/DECISIONS.md](docs/DECISIONS.md). Short version: it needed to be reachable
without friction and without turning something personal into something gated.
