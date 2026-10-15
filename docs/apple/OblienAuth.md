# Oblien Login — Mobile Integration Guide

How to log a user in **exactly the way the dashboard does it**: ask the API for a
login URL, open that URL so the user logs in on the hosted page, then poll until
the login lands on your token. No password fields in your app, no OAuth SDKs —
the hosted page (`auth.oblien.com`) does all of it (email/password, 2FA, Google,
GitHub, Twitter, Apple).

- **API base:** `https://api.oblien.com`
- **Hosted login page:** `https://auth.oblien.com`

---

## TL;DR — the whole flow

```
1. POST /auth/token                      → get an anonymous token  T
2. POST /auth/session  { app:"mobile" }  → get { url }   (using T)
3. open url in a browser / web view      → user logs in there
4. GET  /auth/session/<id>/poll          → poll with T until "authenticated"
5. T is now the logged-in user's token   → use it on every request
```

The key idea: **the token never changes.** Step 1 gives you a token tied to a
server session. The login on the hosted page attaches the user to *that same
session*, so the token you started with becomes the authenticated token. You do
not receive a new token at the end — you keep using `T`.

Everywhere you call the API after that:

```
Authorization: Bearer <T>
```

That single header authenticates the user across the whole API (`/auth`,
`/github`, `/credits`, …). No cookies.

---

## Step 1 — Get a token

Call once on app start (or whenever you have no stored token). No auth needed.

**Request**
```http
POST /auth/token
Content-Type: application/json

{}
```

**Response `200`**
```json
{ "success": true, "token": "eyJhbGciOiJIUzI1Ni, …" }
```

Store the token in the OS secure store (iOS Keychain / Android Keystore). This is
an **anonymous** token — it works but has no user attached yet.

> Renewing without losing login state: pass your current token as `old_token`
> (`{ "old_token": "<T>" }`). A still-valid token keeps the same underlying
> session (so the user stays logged in across the swap); an expired one just
> gives you a fresh anonymous token. Rate limit ~2/sec → `429` if exceeded.

---

## Step 2 — Ask for the login URL

Call this with the **anonymous** token from step 1.

**Request**
```http
POST /auth/session
Authorization: Bearer <T>
Content-Type: application/json

{ "app": "mobile" }
```

**Response `200`**
```json
{ "success": true, "url": "https://auth.oblien.com/V1StGXR8_Z5jdHi6B-myT" }
```

The path segment (`V1StGXR8…`) is the **auth session id** — call it `<id>`.
You need it for the poll in step 4.

Rules:
- `app` is required and must be one of:
  `mobile`, `web`, `domains`, `deploy`, `blurs`, `oblien`. Use `"mobile"`.
- Must be called with an anonymous token. If the token is **already logged in**
  you get `400 { "error": "bad_request", "message": "User already logged in" }`.
- `redirect_url` (optional) — only for web apps that want the page to redirect
  back to them. Mobile opens the URL directly and polls, so **leave it out**. If
  sent, it must be a first-party `*.oblien.com` https URL or it's rejected `400`.

---

## Step 3 — Open the URL

Open `url` in a system browser tab / web view:

- **iOS:** `ASWebAuthenticationSession` (or `SFSafariViewController`).
- **Android:** Chrome Custom Tabs.

The hosted page handles the entire login — password, 2FA prompts, and every
OAuth provider popup. When the user finishes, the page attaches their `user_id`
to **your token's session** server-side. The user can then close the tab.

You don't get a callback from the browser — you find out by polling (step 4).

---

## Step 4 — Poll until logged in

Poll every ~2–3 seconds, **with the same token `T`**, using the `<id>` from step 2.

**Request**
```http
GET /auth/session/<id>/poll
Authorization: Bearer <T>
```

**Response `200`** — one of:

| Body | Meaning | What to do |
|------|---------|------------|
| `{ "status": "pending" }`       | User hasn't finished yet | keep polling |
| `{ "status": "authenticated" }` | Done ✅                  | stop; `T` is now the user's token |
| `{ "status": "expired" }`       | Session timed out        | restart from step 2 |

Other statuses:
- `404 { "status": "not_found" }` — bad/unknown `<id>`.
- `403 { "status": "forbidden" }` — you polled with a token that didn't create
  this session. Only the token from step 2 may poll it.

Once you see `authenticated`, stop polling. **`T` is the logged-in token** — keep
using it.

---

## Step 5 — Read the logged-in user (status)

Use this any time to confirm login state and fetch the current user. It's also
what you call on app launch to check whether your stored token is still good.

**Request**
```http
GET /auth/status
Authorization: Bearer <T>
```

**Response `200` — logged in:**
```json
{
  "authenticated": true,
  "user": {
    "id": "u_7f3a…",
    "name": "Jane Doe",
    "email": "jane@example.com",
    "image": "https://…/avatar.png",
    "statue": "active",
    "show_welcome": false
  }
}
```

**Response `200` — anonymous token (not logged in):**
```json
{
  "authenticated": false,
  "user": {
    "id": null, "name": null, "email": null,
    "image": null, "statue": null, "show_welcome": false
  }
}
```
When not logged in, `authenticated` is `false` and every `user.*` field is `null`
(except `show_welcome`, which is `false`). **Drive your UI off `authenticated`**,
not off individual fields.

### `user` schema

| Field          | Type             | Notes |
|----------------|------------------|-------|
| `id`           | string \| null   | User id. `null` when not authenticated. |
| `name`         | string \| null   | Display name. |
| `email`        | string \| null   | Primary email. |
| `image`        | string \| null   | Avatar URL. May be `null` (e.g. some providers). |
| `statue`       | string \| null   | Account status/tier. **Spelling is intentional** — the JSON key is literally `statue` (not `status`). Don't "fix" it client-side. |
| `show_welcome` | boolean          | `true` once, right after welcome credits are first granted — use it to show a one-time welcome screen. `false` afterwards. Never `null`. |

> `GET /auth/status` returns `200` even for anonymous tokens (with
> `authenticated:false`). A `401` here means the **token itself** is
> expired/invalid/revoked — re-bootstrap (step 1) and send the user through login
> again. A `500` with `{ "error": "database_error" }` is a transient server issue.

---

## Logout

```http
POST /auth/logout
Authorization: Bearer <T>
```
**`200`** `{ "success": true }`

This detaches the user from the session — the token goes back to **anonymous**
(it isn't destroyed). Simplest correct behavior: drop the stored token and
bootstrap a fresh one (step 1) before the next login.

> A password change/reset on the account **revokes all of that user's tokens**
> everywhere. After that your token returns `401 token_revoked` — treat it like a
> forced logout: re-bootstrap and re-login.

---

## Recommended app lifecycle

1. **Launch:** load stored token → `GET /auth/status`.
   - `authenticated:true` → go to the app.
   - `authenticated:false` → token is anonymous; show login (steps 2–4).
   - `401` → token dead; bootstrap a new one (step 1), then show login.
2. **Login:** steps 2 → 3 → 4, poll until `authenticated`.
3. **Every request:** `Authorization: Bearer <T>` (including the GitHub
   clone-token endpoint — see `GITHUB_API.md`).
4. **On any `401` mid-session:**
   - `token_expired` → re-bootstrap (step 1) + re-login.
   - `token_revoked` → password changed / logged out elsewhere → force re-login.
5. **Logout:** `POST /auth/logout`, drop the token.

### Error shape
Auth endpoints return errors as:
```json
{ "success": false, "error": "<code>", "message": "<human readable>" }
```
Status codes you'll see from the auth layer: `400` bad request, `401`
missing/expired/revoked token, `403` forbidden (wrong owner / banned), `429` rate
limited, `500` server error.

---

## Appendix — native login (only if you skip the hosted page)

You normally **don't need this** — the hosted flow above already does passwords,
2FA, and OAuth. Use these only if you're building a fully custom native login UI
and will handle 2FA / email verification yourself. All calls use
`Authorization: Bearer <T>`.

```http
POST /auth/register            { email, password, name, username }   → 201, auto-logs in
POST /auth/login               { email|username, password }
POST /auth/login/verify-2fa    { code }            # after a requires2FA login
POST /auth/verify-email        { code }
POST /auth/resend-verification                      # authenticated
```

`POST /auth/login` results (HTTP `200` unless noted):
- **Success:** `{ "success": true, "user": { … } }` — `T` is now logged in.
- **2FA:** `{ "success": true, "requires2FA": true, "userId", "message" }` →
  `POST /auth/login/verify-2fa { code }` with the **same** token.
- **Email unverified:** `{ "success": false, "requiresEmailVerification": true,
  "code": "EMAIL_NOT_VERIFIED" }` (a code is emailed) →
  `POST /auth/verify-email { code }`.
- **Bad credentials:** `401 { "error": "invalid_credentials" }`.
- **Locked/banned:** `403`.

Direct OAuth (native): `GET /auth/<provider>/url?callback=<first-party-url>` →
`{ url }`; open it, the provider redirects to `/auth/<provider>/callback` which
attaches the user to your session. Providers: `google`, `github`, `twitter`,
`apple`. (The hosted flow wraps all of this — prefer it.)

Password & 2FA management endpoints exist under `/auth/password/*` and
`/auth/2fa/*`; see the route list in `auth/routes.js` if you need them.
