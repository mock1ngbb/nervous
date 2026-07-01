# Architecture

## Components

| Component | What it is | Where it lives |
|---|---|---|
| `nervous-system-states` Worker | Serves the page; runs the gate logic | Cloudflare Workers, custom domain `nervous.mock1ngbb.com` |
| Turnstile widget | Invisible bot-check, sitekey in `config/cloudflare.json` | Cloudflare Turnstile (account-level) |
| `turnstile-siteverify-nervous` Worker | Verifies a Turnstile token server-side | Cloudflare Workers, `*.workers.dev` (no custom domain needed — only the main Worker calls it) |
| `nervous.mock1ngbb.com public bypass` | Access app that exempts this domain from the account's wildcard Access app | Cloudflare Access (Zero Trust) — see [DECISIONS.md](DECISIONS.md) for why this exists despite the "no Zero Trust" goal |

## Request flow

```
Browser
  │
  │  GET https://nervous.mock1ngbb.com/
  ▼
Cloudflare edge
  │  1. Access wildcard app (*.mock1ngbb.com) would normally redirect to
  │     the account's Access login — the "public bypass" app for this exact
  │     hostname short-circuits that with decision=bypass before it fires.
  ▼
nervous-system-states Worker
  │
  ├─ has a valid `ns_verified` cookie? ──yes──▶ env.ASSETS.fetch(request)
  │                                              (serves site/index.html)
  │
  └─ no / invalid cookie
       ▼
     Serve challenge.html:
       - loads Cloudflare's Turnstile script
       - invisible widget auto-executes (no checkbox, no visible UI)
       - on success, browser JS POSTs the token to /__verify
            ▼
          nervous-system-states Worker (/__verify handler)
            │
            │  POST { token }
            ▼
          turnstile-siteverify-nervous Worker
            │  calls Cloudflare's siteverify API with TURNSTILE_SECRET_KEY
            ▼
          { success: true/false }
            │
       success ──▶ sign a timestamp with COOKIE_SECRET (HMAC-SHA256),
                    set-cookie `ns_verified=<ts>.<sig>`, browser JS reloads
                    the page ──▶ now the cookie check above passes.
       failure ──▶ 403, no cookie set, browser JS resets the widget and
                    quietly retries. A bot/headless browser that can't
                    solve the challenge never gets a cookie and never
                    sees the real page.
```

## Why two Workers instead of one

`nervous-system-states` (serves the page + owns the cookie) and
`turnstile-siteverify-nervous` (calls Cloudflare's siteverify API) are separate
deployments. This wasn't necessary — the siteverify call could have been inlined
into `nervous-system-states` directly. It's split because the siteverify Worker is
the *generic, reusable* piece (any project's Turnstile setup can point at the same
kind of Worker — see [Cloudflare's turnstile-spin skill](https://developers.cloudflare.com/turnstile/spin/),
whose template is vendored at `vendor/turnstile-siteverify/`), while
`nervous-system-states` is the *project-specific* piece (this page, this cookie
scheme, this domain). Reusing the generic piece as-is meant not hand-rolling a
second siteverify implementation.

## Why a signed cookie instead of re-challenging every request

Turnstile's invisible mode is fast (~1-2s) but still costs a script load, a
challenge round-trip, and a `/__verify` call. Re-running that on every single
request (including images, if there were any) would be wasteful and would add
latency to every navigation. Instead, a successful verification is remembered for
12 hours via a signed cookie — cheap to check (one HMAC verify, no KV/DB lookup),
cheap to forge-proof (HMAC-SHA256 over a timestamp, secret never leaves the
Worker), and self-expiring (no revocation list needed; a stolen cookie is only
useful until it ages out).
