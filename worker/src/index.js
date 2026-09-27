// save-sync Worker: Google sign-in once per device -> 90-day sliding session ->
// per-sync handout of the bucket-scoped R2 key + rclone crypt key.
//
// Auth lives HERE (not Cloudflare Access): every endpoint except the sign-in
// redirect needs a valid session, and sign-in only succeeds for ALLOWED_EMAIL
// (and, after the first sign-in, only for that account's pinned Google `sub`).
//
// Secrets (wrangler secret put): ALLOWED_EMAIL, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET,
//   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, CRYPT_PASSWORD, CRYPT_SALT
// Vars (wrangler.toml): R2_BUCKET   (the allowed email is a secret so it stays out of this public repo)
// KV: SESSIONS  (session:<sha256(token)>, pending:<sha256(poll)>, owner, rl:<ip>:<min>)

const SESSION_TTL = 90 * 24 * 3600;
const PENDING_TTL = 600;
const TOUCH_EVERY = 24 * 3600;       // refresh the sliding expiry at most daily (KV write budget)
const RATE_PER_MIN = 20;             // per IP, sign-in endpoints only

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    try {
      switch (`${req.method} ${url.pathname}`) {
        case "GET /auth/start":     return await authStart(url, env, req);
        case "GET /auth/callback":  return await authCallback(url, env);
        case "POST /auth/poll":     return await authPoll(req, env);
        case "POST /keys":          return await keys(req, env);
        case "GET /devices":        return await devices(req, env);
        case "DELETE /devices":     return await revoke(req, env, url);
        case "GET /health":         return json({ ok: true });
        default:                    return json({ error: "not found" }, 404);
      }
    } catch (e) {
      console.error(e);
      return json({ error: "internal error" }, 500);
    }
  },
};

// ------------------------------------------------------------------ helpers
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

const page = (msg, status = 200) =>
  new Response(`<!doctype html><meta name=viewport content="width=device-width"><title>save-sync</title>
<body style="font:16px system-ui;max-width:32rem;margin:3rem auto;padding:0 1rem">${msg}</body>`,
    { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });

async function sha256hex(s) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomToken() {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function rateLimited(req, env) {
  const ip = req.headers.get("cf-connecting-ip") || "unknown";
  const key = `rl:${ip}:${Math.floor(Date.now() / 60000)}`;
  const n = parseInt((await env.SESSIONS.get(key)) || "0", 10) + 1;
  await env.SESSIONS.put(key, String(n), { expirationTtl: 120 });
  return n > RATE_PER_MIN;
}

async function session(req, env) {
  const auth = req.headers.get("authorization") || "";
  const tok = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (tok.length < 40) return null;
  const id = await sha256hex(tok);
  const { value, metadata } = await env.SESSIONS.getWithMetadata(`session:${id}`, "json");
  if (!value) return null;
  const now = Math.floor(Date.now() / 1000);
  if (now - (value.touched || 0) > TOUCH_EVERY) {          // sliding 90-day expiry
    value.touched = now;
    await env.SESSIONS.put(`session:${id}`, JSON.stringify(value),
      { expirationTtl: SESSION_TTL, metadata: { device: value.device, created: value.created, touched: now } });
  }
  return { id, ...value };
}

// ------------------------------------------------------------------ sign-in
// Device: makes a random poll secret P, opens /auth/start?h=sha256(P)&device=NAME
// in the browser, then polls POST /auth/poll {p: P}. The session token never
// appears in a URL or browser history.
async function authStart(url, env, req) {
  if (await rateLimited(req, env)) return page("Too many attempts; wait a minute.", 429);
  const h = url.searchParams.get("h") || "";
  const device = (url.searchParams.get("device") || "device").slice(0, 64);
  if (!/^[0-9a-f]{64}$/.test(h)) return page("Bad request.", 400);
  await env.SESSIONS.put(`pending:${h}`, JSON.stringify({ device, state: "started" }), { expirationTtl: PENDING_TTL });
  const g = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  g.search = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: `${url.origin}/auth/callback`,
    response_type: "code",
    scope: "openid email",
    state: h,
    prompt: "select_account",
  });
  return Response.redirect(g.toString(), 302);
}

async function authCallback(url, env) {
  const h = url.searchParams.get("state") || "";
  const code = url.searchParams.get("code") || "";
  const pending = /^[0-9a-f]{64}$/.test(h) ? await env.SESSIONS.get(`pending:${h}`, "json") : null;
  if (!pending || pending.state !== "started" || !code)
    return page("This sign-in link expired. Run <code>savesync login</code> again.", 400);

  const tr = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code, client_id: env.GOOGLE_CLIENT_ID, client_secret: env.GOOGLE_CLIENT_SECRET,
      redirect_uri: `${url.origin}/auth/callback`, grant_type: "authorization_code",
    }),
  });
  const tok = await tr.json();
  if (!tr.ok || !tok.id_token) return page("Google sign-in failed.", 400);
  const claims = await verifyGoogleIdToken(tok.id_token, env.GOOGLE_CLIENT_ID);
  if (!claims) return page("Google sign-in could not be verified.", 400);

  const deny = async () => {
    await env.SESSIONS.put(`pending:${h}`, JSON.stringify({ state: "denied" }), { expirationTtl: 120 });
    return page("This Google account isn't allowed to use this save-sync.", 403);
  };
  if (!claims.email_verified || claims.email.toLowerCase() !== env.ALLOWED_EMAIL.toLowerCase()) return deny();
  const owner = await env.SESSIONS.get("owner");
  if (owner && owner !== claims.sub) return deny();
  if (!owner) await env.SESSIONS.put("owner", claims.sub);           // pin on first sign-in

  const token = randomToken();
  const id = await sha256hex(token);
  const now = Math.floor(Date.now() / 1000);
  const value = { device: pending.device, created: now, touched: now };
  await env.SESSIONS.put(`session:${id}`, JSON.stringify(value),
    { expirationTtl: SESSION_TTL, metadata: { device: value.device, created: now, touched: now } });
  await env.SESSIONS.put(`pending:${h}`, JSON.stringify({ state: "done", token }), { expirationTtl: 300 });
  return page(`Signed in. <b>${escapeHtml(pending.device)}</b> can sync now — you can close this tab.`);
}

async function authPoll(req, env) {
  if (await rateLimited(req, env)) return json({ error: "slow down" }, 429);
  const { p } = await req.json().catch(() => ({}));
  if (typeof p !== "string" || p.length < 40) return json({ error: "bad request" }, 400);
  const h = await sha256hex(p);
  const pending = await env.SESSIONS.get(`pending:${h}`, "json");
  if (!pending) return json({ state: "expired" }, 404);
  if (pending.state === "done") {
    await env.SESSIONS.delete(`pending:${h}`);                        // hand out once
    return json({ state: "done", token: pending.token });
  }
  return json({ state: pending.state });
}

// Google ID token: RS256 signature against Google's JWKS + standard claims.
async function verifyGoogleIdToken(jwt, clientId) {
  const [h64, p64, s64] = jwt.split(".");
  const dec = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  const header = JSON.parse(new TextDecoder().decode(dec(h64)));
  const claims = JSON.parse(new TextDecoder().decode(dec(p64)));
  const jwks = await (await fetch("https://www.googleapis.com/oauth2/v3/certs", { cf: { cacheTtl: 3600 } })).json();
  const jwk = jwks.keys.find((k) => k.kid === header.kid);
  if (!jwk || header.alg !== "RS256") return null;
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, dec(s64), new TextEncoder().encode(`${h64}.${p64}`));
  const now = Date.now() / 1000;
  if (!ok || claims.aud !== clientId || claims.exp < now ||
      !["accounts.google.com", "https://accounts.google.com"].includes(claims.iss)) return null;
  return claims;
}

const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// ------------------------------------------------------------------ keys & devices
async function keys(req, env) {
  const s = await session(req, env);
  if (!s) return json({ error: "signed out" }, 401);
  return json({
    r2: {
      endpoint: `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
      bucket: env.R2_BUCKET,
      access_key_id: env.R2_ACCESS_KEY_ID,
      secret_access_key: env.R2_SECRET_ACCESS_KEY,
    },
    crypt: { password: env.CRYPT_PASSWORD, salt: env.CRYPT_SALT },
  });
}

async function devices(req, env) {
  const s = await session(req, env);
  if (!s) return json({ error: "signed out" }, 401);
  const out = [];
  let cursor;
  do {
    const r = await env.SESSIONS.list({ prefix: "session:", cursor });
    for (const k of r.keys) {
      const id = k.name.slice(8);
      out.push({ id: id.slice(0, 12), this: id === s.id, ...(k.metadata || {}) });
    }
    cursor = r.list_complete ? null : r.cursor;
  } while (cursor);
  return json({ devices: out });
}

async function revoke(req, env, url) {
  const s = await session(req, env);
  if (!s) return json({ error: "signed out" }, 401);
  const prefix = url.searchParams.get("id") || "";
  if (!/^[0-9a-f]{12}$/.test(prefix)) return json({ error: "bad id" }, 400);
  const r = await env.SESSIONS.list({ prefix: `session:${prefix}` });
  if (r.keys.length !== 1) return json({ error: "no such device" }, 404);
  await env.SESSIONS.delete(r.keys[0].name);
  return json({ revoked: prefix });
}
