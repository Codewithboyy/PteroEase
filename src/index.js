const SESSION_SECONDS = 60 * 60 * 12;
const PASSWORD_ITERATIONS = 210000;
const MAX_BODY_BYTES = 16 * 1024;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export default {
  async fetch(request, env) {
    try {
      if (!env.DB || !env.SESSION_PEPPER) {
        return json({ error: "Service is not configured" }, 503);
      }

      const url = new URL(request.url);
      const path = url.pathname;
      const method = request.method.toUpperCase();

      if (method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(request, env) });

      if (path === "/health" && method === "GET") {
        return json({ ok: true, service: "PteroEase Auth" }, 200, request, env);
      }

      if (path === "/" && method === "GET") {
        return html(DASHBOARD, 200, request, env);
      }

      if (path === "/api/register" && method === "POST") return register(request, env);
      if (path === "/api/login" && method === "POST") return browserLogin(request, env);
      if (path === "/api/cli/login" && method === "POST") return cliLogin(request, env);
      if (path === "/api/logout" && method === "POST") return logout(request, env);
      if (path === "/api/me" && method === "GET") return me(request, env);
      if (path === "/api/admin/users" && method === "GET") return listUsers(request, env);
      if (path === "/api/admin/users/approve" && method === "POST") return setApproval(request, env, true);
      if (path === "/api/admin/users/revoke" && method === "POST") return setApproval(request, env, false);

      return json({ error: "Not found" }, 404, request, env);
    } catch (err) {
      // Never return internal exception details to clients.
      console.error("Request failed", err?.name || "Error");
      return json({ error: "Internal server error" }, 500, request, env);
    }
  },
};

async function register(request, env) {
  if (!isJson(request)) return json({ error: "Expected JSON" }, 415, request, env);
  const body = await readJson(request);
  if (!body) return json({ error: "Invalid request body" }, 400, request, env);

  const email = normalizeEmail(body.email);
  const password = typeof body.password === "string" ? body.password : "";
  if (!EMAIL_RE.test(email) || email.length > 254) return json({ error: "Enter a valid email address" }, 400, request, env);
  if (password.length < 12 || password.length > 256) return json({ error: "Password must be 12–256 characters" }, 400, request, env);

  const emailKeyHash = await digest(`${env.SESSION_PEPPER}:register:${email}`);
  const limit = await rateLimit(request, env, `register:${emailKeyHash}`, 5, 3600);
  if (!limit.allowed) return rateLimited(request, env, limit.retryAfter);

  const exists = await env.DB.prepare("SELECT id FROM users WHERE email = ?").bind(email).first();
  if (exists) return json({ ok: true, message: "If the address is eligible, the account will remain pending until approved." }, 202, request, env);

  const id = crypto.randomUUID();
  const passwordHash = await hashPassword(password);
  await env.DB.prepare(
    "INSERT INTO users (id, email, password_hash, role, approved, created_at) VALUES (?, ?, ?, 'user', 0, ?)"
  ).bind(id, email, passwordHash, now()).run();

  return json({ ok: true, message: "Registration received. An administrator must approve your account before you can sign in." }, 202, request, env);
}

async function browserLogin(request, env) {
  const result = await authenticatePassword(request, env);
  if (!result.ok) return result.response;

  const cookie = `pe_session=${result.token}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_SECONDS}`;
  return json({ ok: true, user: publicUser(result.user), csrfToken: result.csrfToken }, 200, request, env, {
    "Set-Cookie": cookie,
    "Cache-Control": "no-store",
  });
}

async function cliLogin(request, env) {
  const result = await authenticatePassword(request, env);
  if (!result.ok) return result.response;
  return json({
    ok: true,
    token: result.token,
    expiresAt: now() + SESSION_SECONDS,
    user: publicUser(result.user),
  }, 200, request, env, { "Cache-Control": "no-store" });
}

async function authenticatePassword(request, env) {
  if (!isJson(request)) return { ok: false, response: json({ error: "Expected JSON" }, 415, request, env) };
  const body = await readJson(request);
  if (!body) return { ok: false, response: json({ error: "Invalid request body" }, 400, request, env) };

  const email = normalizeEmail(body.email);
  const password = typeof body.password === "string" ? body.password : "";
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const ipHash = await digest(`${env.SESSION_PEPPER}:ip:${ip}`);
  const emailHash = await digest(`${env.SESSION_PEPPER}:email:${email}`);

  const ipLimit = await rateLimit(request, env, `login-ip:${ipHash}`, 20, 900);
  const emailLimit = await rateLimit(request, env, `login-email:${emailHash}`, 10, 900);
  if (!ipLimit.allowed || !emailLimit.allowed) {
    return { ok: false, response: rateLimited(request, env, Math.max(ipLimit.retryAfter || 0, emailLimit.retryAfter || 0)) };
  }

  const user = await env.DB.prepare(
    "SELECT id, email, password_hash, role, approved FROM users WHERE email = ?"
  ).bind(email).first();

  // Perform a password check even for unknown users to reduce account-enumeration timing differences.
  const hashToCheck = user?.password_hash || DUMMY_PASSWORD_HASH;
  const passwordOk = await verifyPassword(password, hashToCheck);
  if (!user || !passwordOk || user.approved !== 1) {
    return { ok: false, response: json({ error: "Invalid credentials or account not approved" }, 401, request, env) };
  }

  const token = randomToken(32);
  const tokenHash = await digest(`${env.SESSION_PEPPER}:${token}`);
  const csrfToken = randomToken(24);
  const createdAt = now();
  const expiresAt = createdAt + SESSION_SECONDS;

  await env.DB.prepare(
    "INSERT INTO sessions (id, user_id, token_hash, csrf_token, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)"
  ).bind(crypto.randomUUID(), user.id, tokenHash, csrfToken, createdAt, expiresAt).run();

  return { ok: true, user, token, csrfToken };
}

async function logout(request, env) {
  const auth = await getSession(request, env);
  if (auth?.session) {
    if (auth.mode === "cookie" && !validBrowserMutation(request, auth.session)) {
      return json({ error: "CSRF validation failed" }, 403, request, env);
    }
    await env.DB.prepare("DELETE FROM sessions WHERE id = ?").bind(auth.session.id).run();
  }
  return json({ ok: true }, 200, request, env, {
    "Set-Cookie": "pe_session=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0",
    "Cache-Control": "no-store",
  });
}

async function me(request, env) {
  const auth = await requireUser(request, env);
  if (!auth.ok) return auth.response;
  return json({ ok: true, user: publicUser(auth.user), csrfToken: auth.mode === "cookie" ? auth.session.csrf_token : null }, 200, request, env, {
    "Cache-Control": "no-store",
  });
}

async function listUsers(request, env) {
  const auth = await requireAdmin(request, env);
  if (!auth.ok) return auth.response;
  if (auth.mode === "cookie" && !validBrowserMutation(request, auth.session, true)) {
    // Read-only GET is safe; Origin is checked by browser security policy and no mutation occurs.
  }
  const result = await env.DB.prepare(
    "SELECT id, email, role, approved, created_at FROM users ORDER BY approved ASC, created_at DESC LIMIT 500"
  ).all();
  return json({ ok: true, users: result.results || [] }, 200, request, env, { "Cache-Control": "no-store" });
}

async function setApproval(request, env, approved) {
  const auth = await requireAdmin(request, env);
  if (!auth.ok) return auth.response;
  if (auth.mode === "cookie" && !validBrowserMutation(request, auth.session)) {
    return json({ error: "CSRF validation failed" }, 403, request, env);
  }
  if (!isJson(request)) return json({ error: "Expected JSON" }, 415, request, env);
  const body = await readJson(request);
  const userId = typeof body?.userId === "string" ? body.userId : "";
  if (!userId || userId.length > 64) return json({ error: "userId is required" }, 400, request, env);
  if (userId === auth.user.id && !approved) return json({ error: "You cannot revoke your own active account here" }, 400, request, env);

  const target = await env.DB.prepare("SELECT id, role FROM users WHERE id = ?").bind(userId).first();
  if (!target) return json({ error: "User not found" }, 404, request, env);
  if (!approved && target.role === "admin") {
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM users WHERE role = 'admin' AND approved = 1").first();
    if ((count?.n || 0) <= 1) return json({ error: "Cannot revoke the last active administrator" }, 400, request, env);
  }

  await env.DB.prepare("UPDATE users SET approved = ? WHERE id = ?").bind(approved ? 1 : 0, userId).run();
  if (!approved) await env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(userId).run();
  return json({ ok: true, userId, approved }, 200, request, env);
}

async function requireUser(request, env) {
  const auth = await getSession(request, env);
  if (!auth?.session) return { ok: false, response: json({ error: "Authentication required" }, 401, request, env) };
  if (auth.user.approved !== 1) return { ok: false, response: json({ error: "Account is not approved" }, 403, request, env) };
  return { ok: true, ...auth };
}

async function requireAdmin(request, env) {
  const auth = await requireUser(request, env);
  if (!auth.ok) return auth;
  if (auth.user.role !== "admin") return { ok: false, response: json({ error: "Administrator access required" }, 403, request, env) };
  return auth;
}

async function getSession(request, env) {
  const cookie = parseCookies(request.headers.get("Cookie") || "").pe_session;
  const authorization = request.headers.get("Authorization") || "";
  const bearer = authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  const token = bearer || cookie || "";
  if (!token || token.length > 256) return null;

  const tokenHash = await digest(`${env.SESSION_PEPPER}:${token}`);
  const row = await env.DB.prepare(
    "SELECT s.id, s.user_id, s.csrf_token, s.expires_at, u.email, u.role, u.approved " +
    "FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?"
  ).bind(tokenHash).first();
  if (!row || row.expires_at <= now()) {
    if (row) await env.DB.prepare("DELETE FROM sessions WHERE id = ?").bind(row.id).run();
    return null;
  }
  return {
    mode: bearer ? "bearer" : "cookie",
    session: { id: row.id, csrf_token: row.csrf_token, expires_at: row.expires_at },
    user: { id: row.user_id, email: row.email, role: row.role, approved: row.approved },
  };
}

function validBrowserMutation(request, session) {
  const origin = request.headers.get("Origin");
  const requestUrl = new URL(request.url);
  if (!origin || origin !== requestUrl.origin) return false;
  return request.headers.get("X-CSRF-Token") === session.csrf_token;
}

async function rateLimit(request, env, key, max, windowSeconds) {
  const cutoff = now() - windowSeconds;
  const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM login_attempts WHERE key = ? AND attempted_at > ?")
    .bind(key, cutoff).first();
  if ((count?.n || 0) >= max) {
    const oldest = await env.DB.prepare("SELECT attempted_at FROM login_attempts WHERE key = ? AND attempted_at > ? ORDER BY attempted_at ASC LIMIT 1")
      .bind(key, cutoff).first();
    return { allowed: false, retryAfter: Math.max(1, (oldest?.attempted_at || now()) + windowSeconds - now()) };
  }
  await env.DB.prepare("INSERT INTO login_attempts (key, attempted_at) VALUES (?, ?)").bind(key, now()).run();
  return { allowed: true, retryAfter: 0 };
}

async function readJson(request) {
  const length = Number(request.headers.get("Content-Length") || 0);
  if (length > MAX_BODY_BYTES) return null;
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

function isJson(request) {
  return (request.headers.get("Content-Type") || "").toLowerCase().includes("application/json");
}

function normalizeEmail(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

async function hashPassword(password) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const material = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: PASSWORD_ITERATIONS }, material, 256);
  return `pbkdf2$${PASSWORD_ITERATIONS}$${toB64Url(salt)}$${toB64Url(new Uint8Array(bits))}`;
}

async function verifyPassword(password, encoded) {
  const parts = String(encoded).split("$");
  if (parts.length !== 4 || parts[0] !== "pbkdf2") return false;
  const iterations = Number(parts[1]);
  if (!Number.isInteger(iterations) || iterations < 100000 || iterations > 1000000) return false;
  try {
    const salt = fromB64Url(parts[2]);
    const expected = fromB64Url(parts[3]);
    const material = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
    const bits = new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, material, expected.length * 8));
    if (bits.length !== expected.length) return false;
    let diff = 0;
    for (let i = 0; i < bits.length; i++) diff |= bits[i] ^ expected[i];
    return diff === 0;
  } catch { return false; }
}

async function digest(value) {
  return toB64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}

function randomToken(bytes) {
  return toB64Url(crypto.getRandomValues(new Uint8Array(bytes)));
}
function toB64Url(bytes) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
function fromB64Url(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(base64);
  return Uint8Array.from(binary, c => c.charCodeAt(0));
}
function parseCookies(value) {
  const out = {};
  for (const part of value.split(";")) {
    const i = part.indexOf("=");
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}
function publicUser(user) {
  return { id: user.id, email: user.email, role: user.role, approved: user.approved === 1 };
}
function now() { return Math.floor(Date.now() / 1000); }

function json(data, status = 200, request = null, env = null, extraHeaders = {}) {
  const headers = new Headers({
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
  });
  for (const [k, v] of Object.entries(extraHeaders)) headers.set(k, v);
  for (const [k, v] of Object.entries(corsHeaders(request, env))) headers.set(k, v);
  return new Response(JSON.stringify(data), { status, headers });
}
function html(content, status = 200, request = null, env = null) {
  const headers = new Headers({
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
  });
  for (const [k, v] of Object.entries(corsHeaders(request, env))) headers.set(k, v);
  return new Response(content, { status, headers });
}
function corsHeaders(request, env) {
  // The dashboard and API are same-origin. No cross-origin browser access is enabled.
  return { "Vary": "Origin" };
}

const DUMMY_PASSWORD_HASH = "pbkdf2$210000$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const DASHBOARD = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PteroEase Access</title><style>
:root{color-scheme:dark;font:16px system-ui;background:#0b1020;color:#e9eefb}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:20px}.wrap{width:min(920px,100%)}.panel{background:#121a2d;border:1px solid #293653;border-radius:18px;padding:24px;margin:12px 0}h1,h2{margin-top:0}p{color:#b4bfd5}label{display:block;margin:12px 0 6px}input,button{font:inherit;padding:12px;border-radius:10px;border:1px solid #405173;width:100%;background:#0d1425;color:#fff}button{cursor:pointer;background:#315de5;border:0;margin-top:12px;font-weight:650}button.secondary{background:#293653}button.danger{background:#923d54}.row{display:flex;gap:10px;align-items:center}.row button{width:auto}.hidden{display:none}.msg{min-height:24px;color:#f2c879;white-space:pre-wrap}.user{display:grid;grid-template-columns:1fr auto;gap:12px;padding:12px 0;border-bottom:1px solid #293653}.pill{font-size:12px;color:#b4bfd5}.small{font-size:13px;color:#9eabc5}@media(max-width:560px){.user{grid-template-columns:1fr}.row{flex-wrap:wrap}}
</style></head><body><main class="wrap"><h1>PteroEase Access</h1><p>Management dashboard for individually approved accounts.</p>
<section id="auth" class="panel"><h2>Sign in</h2><form id="login"><label>Email</label><input id="email" type="email" autocomplete="username" required maxlength="254"><label>Password</label><input id="password" type="password" autocomplete="current-password" required maxlength="256"><button>Sign in</button></form><hr><h2>Request access</h2><form id="register"><label>Email</label><input id="newEmail" type="email" required maxlength="254"><label>Password (12+ characters)</label><input id="newPassword" type="password" minlength="12" maxlength="256" required autocomplete="new-password"><button class="secondary">Request approval</button></form><div id="authMsg" class="msg" role="status"></div></section>
<section id="dash" class="panel hidden"><div class="row"><div style="flex:1"><h2>Management</h2><div id="identity" class="small"></div></div><button id="logout" class="secondary">Sign out</button></div><div id="notice" class="msg" role="status"></div><div id="users"></div></section>
<script>
let csrf=null, current=null;
const $=id=>document.getElementById(id);
async function api(path,body=null,method='POST'){const headers={'Content-Type':'application/json'};if(csrf)headers['X-CSRF-Token']=csrf;const r=await fetch(path,{method,headers,credentials:'same-origin',body:body===null?undefined:JSON.stringify(body)});let d={};try{d=await r.json()}catch{}if(!r.ok)throw Error(d.error||('HTTP '+r.status));return d}
function showMessage(id,text){$(id).textContent=text}
async function load(){try{const d=await api('/api/me',null,'GET');current=d.user;csrf=d.csrfToken; $('auth').classList.add('hidden');$('dash').classList.remove('hidden');$('identity').textContent=current.email+' · '+current.role; if(current.role==='admin')await loadUsers();else $('users').textContent='Your account is approved. Admin functions are restricted.';}catch{$('auth').classList.remove('hidden');$('dash').classList.add('hidden')}}
async function loadUsers(){const d=await api('/api/admin/users',null,'GET');$('users').replaceChildren();const h=document.createElement('h2');h.textContent='Approved-user management';$('users').append(h);for(const u of d.users){const row=document.createElement('div');row.className='user';const info=document.createElement('div');const strong=document.createElement('strong');strong.textContent=u.email;const meta=document.createElement('div');meta.className='pill';meta.textContent=(u.role||'user')+' · '+(u.approved?'approved':'pending');info.append(strong,meta);const actions=document.createElement('div');actions.className='row';if(!u.approved){const b=document.createElement('button');b.textContent='Approve';b.onclick=()=>changeUser('/api/admin/users/approve',u.id);actions.append(b)}else if(u.id!==current.id){const b=document.createElement('button');b.className='danger';b.textContent='Revoke';b.onclick=()=>changeUser('/api/admin/users/revoke',u.id);actions.append(b)}row.append(info,actions);$('users').append(row)}}
async function changeUser(path,userId){try{await api(path,{userId});showMessage('notice','Access updated.');await loadUsers()}catch(e){showMessage('notice',e.message)}}
$('login').onsubmit=async e=>{e.preventDefault();try{const d=await api('/api/login',{email:$('email').value,password:$('password').value});csrf=d.csrfToken;showMessage('authMsg','Signed in.');await load()}catch(e){showMessage('authMsg',e.message)}finally{$('password').value=''}};
$('register').onsubmit=async e=>{e.preventDefault();try{const d=await api('/api/register',{email:$('newEmail').value,password:$('newPassword').value});showMessage('authMsg',d.message);$('newPassword').value=''}catch(e){showMessage('authMsg',e.message)}};
$('logout').onclick=async()=>{try{await api('/api/logout',{})}catch{}csrf=null;current=null;await load()};
load();
</script></main></body></html>`;
