import CHALLENGE_HTML_TEMPLATE from "./challenge.html";

// Deliberate no-op comment (2026-07-06): proving the Cicada CI/CD pipeline
// (cicd-intake -> cicd-queue -> deploy) actually deploys this repo end-to-end
// on a push to main, matching this file's watch_paths entry in
// .bifrost/deploy-manifest.json. See "Why the Cicada CI/CD manifest isn't
// fully trusted yet" in docs/DECISIONS.md.
//
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
// Cloudflare's own published always-fails dummy token (documented for
// exactly this kind of secret-health probe — a real secret always rejects
// it with error-code "invalid-input-response", never "invalid-input-secret").
const DUMMY_TOKEN = "2x0000000000000000000000000000000AA";
let cachedHealth = null; // { at: epoch-seconds, body: {...} } — see handleHealth

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

// Cloudflare's error-codes array is the ONE signal that can distinguish
// "the token was bad" from "our own secret is wrong" — an HTTP status alone
// (what scripts/verify.sh checked before) cannot, since both cases can
// surface as a plain success:false. See "Why handleVerify is four-way, not
// three" in DECISIONS.md.
const SECRET_SIDE_CODES = new Set(["missing-input-secret", "invalid-input-secret"]);

async function callSiteverify(secret, token) {
  const vr = await fetch(CF_SITEVERIFY_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ secret, response: token }),
  });
  if (!vr.ok) throw new Error(`siteverify HTTP ${vr.status}`);
  const vjson = await vr.json();
  if (typeof vjson.success !== "boolean") throw new Error("siteverify returned an unexpected shape");
  return vjson;
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

  // Four-way outcome, deliberately distinct from a bare try/catch: the
  // client already solved the invisible challenge before this call ever
  // fires, so ANY rejection that isn't "the token itself was bad" is OUR
  // misconfiguration, not the visitor's fault, and must fail OPEN rather
  // than strand them — this is what replaced the incident where
  // vendor/turnstile-siteverify disappeared from the account and every
  // verify call 500'd. Fail-open-on-wrong-secret is only safe because a
  // scheduled /__health probe (see handleHealth below) surfaces that
  // degraded state to a human within minutes instead of it going unnoticed —
  // that alarm is a hard dependency of this trade, not optional polish.
  let vjson;
  try {
    vjson = await callSiteverify(env.TURNSTILE_SECRET_KEY, token);
  } catch (err) {
    console.error("siteverify unreachable, failing open", { error: String(err) });
    return issueVerifiedCookie(env);
  }

  if (vjson.success === true) {
    return issueVerifiedCookie(env);
  }

  const codes = Array.isArray(vjson["error-codes"]) ? vjson["error-codes"] : [];
  if (codes.some((c) => SECRET_SIDE_CODES.has(c))) {
    console.error("siteverify rejected our own secret — gate misconfigured, failing open", { codes });
    return issueVerifiedCookie(env);
  }

  // Token-side rejection (invalid-input-response, timeout-or-duplicate,
  // missing-input-response, bad-request, ...) — the token itself was bad.
  // Fail closed; this is the only case that should ever land here.
  return new Response(JSON.stringify({ success: false, reason: "token" }), {
    status: 403,
    headers: { "content-type": "application/json" },
  });
}

// GET-only, cookie-free health probe: answers "does this Worker currently
// hold a secret that Cloudflare's siteverify actually accepts?" — the exact
// question a bogus-token POST to /__verify cannot answer, since Cloudflare
// rejects a bogus token identically whether the secret is right or wrong.
// Uses Cloudflare's own published always-fails dummy token, so this never
// consumes a real visitor's token and needs no browser. Cached briefly since
// the answer only changes on redeploy/secret rotation, not per-request.
const HEALTH_CACHE_TTL_SECONDS = 45;

async function handleHealth(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedHealth && now - cachedHealth.at < HEALTH_CACHE_TTL_SECONDS) {
    return Response.json(cachedHealth.body, { status: cachedHealth.status });
  }

  let result;
  try {
    const vjson = await callSiteverify(env.TURNSTILE_SECRET_KEY, DUMMY_TOKEN);
    const codes = Array.isArray(vjson["error-codes"]) ? vjson["error-codes"] : [];
    if (codes.some((c) => SECRET_SIDE_CODES.has(c))) {
      result = { status: 503, body: { gate: "degraded", reason: "secret" } };
    } else {
      // vjson.success should be false here (it's a dummy token) with a
      // token-side code — that's the healthy state: our secret is fine,
      // Cloudflare correctly rejected the dummy token on its own merits.
      result = { status: 200, body: { gate: "ok" } };
    }
  } catch (err) {
    // Deliberately 200, not 503: a transient Cloudflare/network blip must
    // never trip a deploy gate or page alarm — only a persistent, actionable
    // secret misconfiguration should. See DECISIONS.md.
    result = { status: 200, body: { gate: "degraded", reason: "unreachable" } };
  }

  cachedHealth = { at: now, status: result.status, body: result.body };
  return Response.json(result.body, { status: result.status });
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
    if (url.pathname === "/__health" && request.method === "GET") {
      return handleHealth(env);
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
