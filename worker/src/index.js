import CHALLENGE_HTML_TEMPLATE from "./challenge.html";

// See docs/ARCHITECTURE.md for the full request-flow diagram and
// docs/DECISIONS.md for why each of these choices was made — including why
// this Worker calls Cloudflare's siteverify endpoint directly instead of
// through vendor/turnstile-siteverify (kept in the repo as reference only;
// no longer a runtime dependency — see "Why we no longer run a separate
// siteverify Worker" in DECISIONS.md).
const CF_SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
const SITEKEY = "0x4AAAAAADtrRqqg8PPu3Edz";
const COOKIE_NAME = "ns_verified";
const COOKIE_TTL = 60 * 60 * 12; // 12h

const CHALLENGE_HTML = CHALLENGE_HTML_TEMPLATE.replace("__SITEKEY__", SITEKEY);

async function sign(value, secret) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function isVerified(cookieHeader, secret) {
  if (!cookieHeader) return false;
  const match = cookieHeader.match(new RegExp(`${COOKIE_NAME}=([^;]+)`));
  if (!match) return false;
  const [ts, sig] = decodeURIComponent(match[1]).split(".");
  if (!ts || !sig) return false;
  const age = Date.now() / 1000 - Number(ts);
  if (!(age >= 0 && age < COOKIE_TTL)) return false;
  const expected = await sign(ts, secret);
  return expected === sig;
}

async function handleVerify(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    body = {};
  }
  const token = body && body.token;
  if (!token) {
    return new Response(JSON.stringify({ success: false }), {
      status: 400,
      headers: { "content-type": "application/json" },
    });
  }

  // Three-way outcome, deliberately distinct from a plain try/catch around
  // everything: an affirmative "token is bad" from Cloudflare must stay
  // fail-closed (403), but Cloudflare being unreachable or returning
  // something unparseable must fail OPEN, not throw a 500. Rationale: the
  // client already solved the invisible challenge before this call ever
  // fires, so fail-open here means "trust the token the widget already
  // vetted when we can't double-check it," not "let anyone in" — and this
  // page's bot-abuse value is near zero, so a degraded-gate window during a
  // Cloudflare-side or network blip is far lower cost than silently
  // stranding a real visitor on the challenge shell forever (the incident
  // this replaced: vendor/turnstile-siteverify disappeared from the account
  // and every verify call 500'd — see DECISIONS.md).
  let vjson;
  try {
    const vr = await fetch(CF_SITEVERIFY_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ secret: env.TURNSTILE_SECRET_KEY, response: token }),
    });
    if (!vr.ok) throw new Error(`siteverify HTTP ${vr.status}`);
    vjson = await vr.json();
  } catch (err) {
    console.error("siteverify unreachable, failing open", { error: String(err) });
    return issueVerifiedCookie(env);
  }

  if (vjson.success === false) {
    return new Response(JSON.stringify({ success: false }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }
  if (vjson.success !== true) {
    console.error("siteverify returned an unexpected shape, failing open", { vjson });
    return issueVerifiedCookie(env);
  }

  return issueVerifiedCookie(env);
}

async function issueVerifiedCookie(env) {
  const ts = Math.floor(Date.now() / 1000).toString();
  const sig = await sign(ts, env.COOKIE_SECRET);
  const cookieVal = encodeURIComponent(`${ts}.${sig}`);
  return new Response(JSON.stringify({ success: true }), {
    status: 200,
    headers: {
      "content-type": "application/json",
      "set-cookie": `${COOKIE_NAME}=${cookieVal}; Path=/; Max-Age=${COOKIE_TTL}; Secure; HttpOnly; SameSite=Lax`,
    },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/__verify" && request.method === "POST") {
      return handleVerify(request, env);
    }

    const verified = await isVerified(request.headers.get("Cookie"), env.COOKIE_SECRET);
    if (verified) {
      // env.ASSETS.fetch() returns a Response with a shared-cacheable
      // Cache-Control by default (Workers Assets are meant to be cached at
      // Cloudflare's edge). That's wrong here: whether this response is
      // servable at all depends on a Worker-computed cookie check that the
      // shared cache layer has no visibility into. Without an explicit
      // no-store, the edge can (and did, during testing) cache this
      // authenticated response and serve it to every subsequent visitor
      // regardless of their own cookie — a full bypass of the gate. See
      // docs/MAINTENANCE.md#known-quirks.
      const assetResponse = await env.ASSETS.fetch(request);
      const response = new Response(assetResponse.body, assetResponse);
      response.headers.set("Cache-Control", "private, no-store");
      return response;
    }

    return new Response(CHALLENGE_HTML, {
      headers: {
        "content-type": "text/html;charset=utf-8",
        "cache-control": "private, no-store",
      },
    });
  },
};
