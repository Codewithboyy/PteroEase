# PteroEase Cloudflare Auth

A Cloudflare Worker + D1 authentication service for a public PteroEase repository. Only individually approved users can sign in. Admin-only endpoints manage approval and revocation.

## Security model

- The repository contains source only. It has no Worker secrets, account tokens, passwords, database credentials, or real database ID.
- Passwords are PBKDF2-HMAC-SHA-256 hashes (210,000 iterations) with random salts.
- The Worker stores hashes of opaque random session tokens in D1; raw tokens are returned only at login.
- Browser sessions use `HttpOnly; Secure; SameSite=Strict` cookies. Mutating browser API calls require same-origin `Origin` and a per-session CSRF token.
- CLI sessions use bearer tokens stored under `~/.config/pteroease/session-token` with restrictive permissions.
- New registrations are pending. An active admin must approve them.
- Revoking an account also deletes its sessions. Sessions expire after 12 hours.
- Login/register endpoints use D1-backed rate limits. Consider enabling Cloudflare WAF/rate-limiting rules too.
- All admin endpoints enforce the role on the server; hiding UI controls is not security.

## Important limitation

A public Bash script can be modified by its owner. This service protects the Worker dashboard and Worker API, not arbitrary local actions in a modified copy of an installer. Any privileged operation that must remain controlled must execute on a trusted server or use a separately authenticated target API.

## Requirements

- A Cloudflare account with Workers and D1 access.
- Node.js and npm/npx on the deployment machine.
- Wrangler CLI (the commands below use `npx wrangler`).
- A terminal with Bash, curl, and Python 3 for the CLI client.

## 1. Create D1 and apply schema

From this directory:

```bash
npx wrangler d1 create pteroease-auth-db
```

Copy the returned `database_id` into `wrangler.toml`, replacing `REPLACE_WITH_YOUR_D1_DATABASE_ID`.

Apply the schema:

```bash
npx wrangler d1 migrations apply pteroease-auth-db --remote
```

If Wrangler reports no migrations, verify `migrations_dir` and that the migration file is committed.

## 2. Set the server-side secret

Generate a strong random secret locally, then set it directly as a Worker secret. Do not paste it into source code or commit it.

```bash
openssl rand -base64 48 | tr -d '\n' | npx wrangler secret put SESSION_PEPPER
```

If your shell/tooling cannot safely pipe the value, run `openssl rand -base64 48`, copy the output, and use `npx wrangler secret put SESSION_PEPPER`; paste the value only into the secret prompt. This secret is used to domain-separate and hash IP identifiers and session tokens.

Deploy:

```bash
npx wrangler deploy
```

The Worker URL will look like `https://pteroease-auth.<your-subdomain>.workers.dev`. Use HTTPS only.

## 3. Create the first administrator

The first admin must be provisioned out-of-band through D1. Do not add a public bootstrap-admin route.

Run this helper locally. It prompts for a password without echoing it and prints a SQL `INSERT` statement containing only a salted password hash:

```bash
node scripts/hash-password.mjs admin@example.com
```

Copy the generated SQL into the Cloudflare dashboard's D1 console for `pteroease-auth-db` and execute it. Replace the example email with your own. The helper's output is a password hash, but still treat it as sensitive operational data.

Then sign in at the Worker URL. The first admin can approve pending accounts in the dashboard.

## 4. Use the browser dashboard

Open the Worker URL, sign in with the seeded admin account, and review pending registrations. Approve only people you know and intend to authorize. Revoke access when needed; revocation deletes their active sessions.

Registration is open but grants no access by itself. If you do not want public registration, you can disable `/api/register` in `src/index.js` and deploy; admins can then provision accounts out-of-band with the helper and D1 console.

## 5. Use the Bash client

```bash
chmod +x client/pteroease-auth.sh
./client/pteroease-auth.sh configure
./client/pteroease-auth.sh login
./client/pteroease-auth.sh status
./client/pteroease-auth.sh users
```

The client asks for the Worker HTTPS URL and saves it in `~/.config/pteroease/auth-url`. Session tokens are stored in `~/.config/pteroease/session-token`, with owner-only permissions. Do not share this file. Anyone who obtains a live token can use that account until expiry or revocation.

Commands:
- `users` — admin only
- `approve USER_ID` — admin only
- `revoke USER_ID` — admin only
- `logout` — invalidates the server session and removes the local token

## 6. Connect existing PteroEase tooling

Use the client as a management client, not as proof that local installer code is trustworthy. For any future protected operation, add a dedicated Worker endpoint and authorize it server-side. Do not create a generic endpoint that runs arbitrary shell commands. Do not embed a Cloudflare API token or shared secret in Bash.

## Operations and hardening

- Keep the Worker and Wrangler dependencies current.
- Restrict access to the Cloudflare account with MFA and least-privilege roles.
- Enable Cloudflare WAF/rate-limiting controls appropriate to your plan.
- Monitor Worker logs without logging passwords, tokens, request bodies, or session cookies.
- Review and periodically prune old `login_attempts` and expired `sessions` rows.
- Consider Cloudflare Access in front of a private admin-only deployment if every dashboard visitor is within one controlled organization.
- Before production use, test account approval, revocation, expiry, CSRF rejection, admin/user role enforcement, and backup/recovery.
