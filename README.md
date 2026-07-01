# nervous

A single static page — [Nervous System States & Somatic Experience](site/index.html), a
mobile-first reference chart on sympathetic/parasympathetic nervous system states —
served from a Cloudflare Worker at **nervous.mock1ngbb.com**, sitting behind an
**invisible** Cloudflare Turnstile bot-check. No visible CAPTCHA, no login, no
Cloudflare Access/Zero Trust identity gate. Just the content, protected quietly.

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

Full writeup in [docs/DECISIONS.md](docs/DECISIONS.md), but the short version: the
page needed to go live without an obtrusive CAPTCHA and without pulling it into the
account's Cloudflare Access (Zero Trust) setup, which already gates most of
`*.mock1ngbb.com` by default. So it's a from-scratch Worker: invisible Turnstile,
verified server-side, backed by a short-lived signed cookie so repeat visits skip
the challenge entirely.
