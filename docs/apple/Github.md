# GitHub API — Internal Integration Guide

Audience: the Oblien app team (mobile + web) integrating with the GitHub
endpoints exposed under `/github`.

This module lets a signed-in Oblien user connect their GitHub account (via the
**Oblien GitHub App**), browse their repositories/organizations, and — for the
mobile app — mint **short-lived, repository-scoped clone tokens** to `git clone`
private repos without ever handling a long-lived credential.

---

## 1. Architecture & trust model

- Authentication to GitHub is done through a **GitHub App** (not user OAuth PATs
  for data access). The app is installed by a user/org; each installation grants
  the app access to selected repositories.
- **GitHub installations are the source of truth for access.** Our DB only
  stores the link `user → installation_id → owner` (the `connects` table). It
  never decides _which repos_ a user may reach — GitHub does, at token-mint time.
- Tokens used for repo operations are **installation access tokens**, minted
  on demand and cached for ~50 min (they expire at 1h, GitHub-enforced).
- Some user-level lookups (`/status`, `/user/orgs`, installations list) use the
  user's stored GitHub OAuth token (the "admin" path).
- Public repository metadata can be read **unauthenticated** when the user has no
  installation for that owner (no broad fallback credential exists).

---

## 2. Authentication (calling our API)

Every `/github/*` endpoint requires a valid Oblien **session JWT**:

```
Authorization: Bearer <oblien_session_jwt>
```

Requests without a valid session, or whose session has no `user_id`, are
rejected with `401`. (The only unauthenticated GitHub-related route is the App
webhook receiver `POST /webhook/github`, which is internal and signed by GitHub —
not part of this API.)

CORS is restricted to `*.oblien.com` and localhost. Auth is Bearer-only (no
cookies), so there is no CSRF surface.

---

## 3. Conventions

### 3.1 Path parameter validation

`owner`, `repo`, and `org` path segments are strictly validated **before** they
touch the GitHub API, to prevent path/URL injection:

| Param   | Rule                                                                 |
|---------|----------------------------------------------------------------------|
| `owner` / `org` | GitHub login: 1–39 chars, `[A-Za-z0-9]` + single hyphens, no leading/trailing hyphen |
| `repo`  | 1–100 chars from `[A-Za-z0-9._-]`; never `.` or `..`                  |

A malformed value returns:

```json
{ "success": false, "error": "validation_error", "code": "validation_error", "message": "Invalid owner parameter" }
```

with HTTP `400`.

### 3.2 Error shapes

Two shapes exist in this module:

- **New / hardened endpoints** (clone-token) use the standard error envelope with
  correct HTTP status codes:

  ```json
  { "success": false, "error": "<code>", "code": "<code>", "message": "<human readable>" }
  ```

- **Legacy list/read endpoints** historically return `{ "error": "..." }` and may
  use HTTP `200` even on a logical failure. **Always branch on the presence of an
  `error` field**, not solely on HTTP status, for these endpoints. They are noted
  individually below.

### 3.3 Rate limits

- A global limiter applies to all routes.
- `POST /github/repos/:owner/:repo/clone-token` has a stricter limiter
  (~2 req/sec per principal). On exceed: HTTP `429`
  `{ "error": "too_many_requests", "message": "Too many token requests, please try again later" }`.

---

## 4. Endpoints

Base path: `/github`

### 4.1 Connection & status

#### `GET /status`
Current GitHub connection status for the user.

- **Connected** → `200`:
  ```json
  { "success": true, "connected": true, "login": "octocat", "id": 1, "avatar_url": "…", "...": "full GitHub user object" }
  ```
- **Not connected** → `200`:
  ```json
  { "success": false, "connected": false, "message": "Not connected" }
  ```

#### `POST /connect`
Begin connecting / installing the GitHub App. Returns a redirect URL the client
should open in a browser.

```json
{ "success": true, "redirectUrl": "https://github.com/apps/oblien/installations/new?state=<state>" }
```

After the user installs the app, GitHub fires an `installation` webhook that
creates the `connects` link automatically.

#### `POST /disconnect`
Remove all installations links + clear the stored OAuth token for the user.

```json
{ "success": true, "message": "Disconnected from GitHub" }
```

#### `GET /user/orgs`
Accounts (user + orgs) where the Oblien App is installed for this user.

```json
[ { "login": "octocat", "id": 1, "avatar_url": "…", "type": "User" },
  { "login": "acme-inc", "id": 42, "avatar_url": "…", "type": "Organization" } ]
```

#### `GET /user/home`
Convenience aggregate for the home screen: status + first account's repos +
all installed accounts.

```json
{
  "status":  { "success": true, "connected": true, "login": "octocat", "...": "…" },
  "repos":   [ /* mapped repo objects, see §4.2 */ ],
  "accounts":[ { "login": "octocat", "id": 1, "avatar_url": "…", "type": "User" } ]
}
```

---

### 4.2 Repositories

The **mapped repo object** returned by listing endpoints:

```json
{
  "full_name": "octocat/hello",
  "name": "hello",
  "owner": "octocat",
  "description": "…",
  "html_url": "https://github.com/octocat/hello",
  "license": { "...": "…" },
  "private": false,
  "visibility": "public",
  "forks": 0,
  "watchers": 0,
  "default_branch": "main",
  "language": "JavaScript",
  "size": 1234,
  "stars": 0,
  "updated_at": "…", "created_at": "…", "pushed_at": "…",
  "deployed": false        // project_id (string) if deployed on Oblien, else false — only on some lists
}
```

#### `GET /repos/user?owner=<login>`
Repos the user owns. `owner` is optional; defaults to the connected user's login.
Returns an **array** of mapped repos, or `{ "error": "…", "message": "…" }`.

#### `GET /orgs/:org/repos`
Repos for an installed organization. Returns an **array** of mapped repos.

#### `GET /repos/orgs`
All of the user's orgs, each with its repos:

```json
[ { "org": { "login": "acme-inc", "id": 42, "avatar_url": "…" },
    "repos": [ /* mapped repos */ ] } ]
```

#### `GET /repo/:owner/:repo`
Single repository details (works for public repos even without an installation).

```json
{
  "id": 123, "name": "hello", "full_name": "octocat/hello", "owner": "octocat",
  "private": false, "default_branch": "main",
  "clone_url": "https://github.com/octocat/hello.git",
  "ssh_url": "git@github.com:octocat/hello.git",
  "html_url": "https://github.com/octocat/hello",
  "branches": []
}
```
On failure: `{ "error": "…" }` (HTTP 200) or `404` `{ "error": "Failed to fetch repository" }`.

#### `GET /repos/:owner/:repo/branches`
Raw GitHub branches array for the repo.

#### `GET /repos/:owner/:repo/files`
Repository contents at the root (`main` branch). Returns the raw GitHub
[contents](https://docs.github.com/en/rest/repos/contents) response (array of
file/dir entries).

#### `POST /repos/create`
Create a repository (under the user, or under `owner` if it's an installed org).

Body:
```json
{ "name": "new-repo", "description": "optional", "private": true, "owner": "acme-inc", "app_id": "<required>" }
```
- `name` and `app_id` are required (`400` otherwise).
- Success: `{ "success": true, "data": { /* GitHub repo object */ } }`
- Failure: `{ "success": false, "error": "…" }`

---

### 4.3 Clone token (mobile) — primary endpoint

#### `POST /repos/:owner/:repo/clone-token`

Mints a **short-lived, repository-scoped, read-only** GitHub installation token
for cloning. This is the credential the mobile app should use — never embed a
long-lived token in the client.

**Request** — no body; `owner`/`repo` come from the path:
```
POST /github/repos/octocat/hello/clone-token
Authorization: Bearer <oblien_session_jwt>
```

**Success — `200`:**
```json
{
  "success": true,
  "token": "ghs_xxxxxxxxxxxxxxxxxxxx",
  "expires_at": "2026-06-23T12:34:56Z",
  "permissions": { "contents": "read", "metadata": "read" },
  "repository": "octocat/hello",
  "clone_url": "https://x-access-token:ghs_xxxx@github.com/octocat/hello.git"
}
```

**Use it:**
```bash
git clone "https://x-access-token:<token>@github.com/<owner>/<repo>.git"
# or with an existing checkout:
git -c http.extraheader="AUTHORIZATION: bearer <token>" fetch origin
```

**Token properties (security):**
- Scoped to **only** `<owner>/<repo>` — cannot read any other repo.
- Permissions: **`contents:read` + `metadata:read` only** — cannot push, cannot
  modify settings, cannot open issues/PRs.
- Expires at `expires_at` (~1 hour). Mint a fresh token per clone session; do not
  cache it on the device beyond its lifetime.
- Treat `clone_url` as a secret (it embeds the token). Prefer passing the token
  via the `AUTHORIZATION` header over embedding it in the URL where possible, to
  avoid it landing in process listings / logs.

**Error responses (standard envelope, real HTTP status):**

| Status | `code`             | When |
|--------|--------------------|------|
| `400`  | `validation_error` | Malformed `owner`/`repo` |
| `403`  | `no_installation`  | User has no Oblien App installation for `owner` → prompt them to install/connect |
| `404`  | `repo_inaccessible`| Repo isn't part of the installation (private + not granted, or doesn't exist) |
| `429`  | `too_many_requests`| Rate limited |
| `500`  | `server_error`     | Unexpected failure |

Example:
```json
{ "success": false, "error": "no_installation", "code": "no_installation",
  "message": "No GitHub App installation found for this account. Install the app on this account first." }
```

**Authorization guarantee:** the installation id is resolved from
`(authenticated user, owner)`, so a user can only ever obtain a token for an
account they personally connected the app to. GitHub independently verifies the
repo belongs to that installation, so there is no way to mint a token for a repo
the installation cannot access.

---

### 4.4 Webhooks (legacy / per-repo push hooks)

These manage a per-repository push webhook pointing at Oblien. Created hooks are
HMAC-signed with the app's webhook secret. `owner`/`repo` are path params.

#### `POST /:owner/:repo/webhook/create`
```json
{ "success": true, "hook_id": 123, "events": ["push"], "active": true }
```

#### `GET /:owner/:repo/webhook`
```json
{ "success": true, "webhook": [ { /* GitHub hook objects */ } ] }
```

#### `DELETE /:owner/:repo/webhook/delete`
Requires the hook to exist; on success:
```json
{ "success": true, "message": "Webhook deleted" }
```

---

## 5. Typical mobile flow

1. `GET /github/status` → if `connected:false`, call `POST /github/connect` and
   open `redirectUrl` so the user installs the app.
2. `GET /github/user/home` (or `/user/orgs` + `/repos/user`) to list accounts and
   repositories.
3. When the user opens a repo to clone:
   `POST /github/repos/:owner/:repo/clone-token` → use the returned `clone_url` /
   `token` immediately with `git clone`.
4. The token expires in ~1h; if a long operation needs a fresh token, request a
   new one. Do not persist tokens.

---

## 6. Notes for implementers

- The `clone-token` endpoint is the only one designed for, and hardened to,
  external/mobile consumption — it has correct status codes, strict validation,
  least-privilege tokens, and dedicated rate limiting.
- Legacy list/read endpoints can return `{ error }` with HTTP `200`; always
  inspect the body.
- Never log `token` / `clone_url` values. They are bearer credentials.
- A `403 no_installation` means the user must (re)install the Oblien GitHub App on
  that account — surface a "Connect GitHub" action, not a hard error.
