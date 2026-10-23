# Agent authentication

The daemon owns the available methods and their order. Clients render the returned
labels and forms; they do not infer subscription support from a harness name.
Codex and Claude list subscription sign-in first, followed by API/cloud methods.

| Harness | First method | Native flow |
|---|---|---|
| Codex | `login` — Continue with ChatGPT | `codex app-server`, `account/login/start` with `type: chatgpt` |
| Claude Code | `login` — Continue with Claude | `claude auth login --claudeai`, browser URL and authorization-code input |

Codex returns its native browser authorization URL, including a loopback
`redirect_uri`. The Apple client opens in-app Safari and temporarily forwards that
exact loopback port over the existing private computer connection (including a
pinned cloud SSH grant). On the same Mac, the native callback is already local.
The authorization URL is never rewritten, no callback is exposed publicly, and
Codex validates OAuth state/PKCE and owns token exchange, storage and refresh.
This flow does not require enabling device-code authorization in ChatGPT.
Claude's native CLI supplies a hosted code callback; the client sends the
resulting code to its stdin.

## Shared client flow

All routes are authenticated with the daemon bearer token and scoped by
`?agent=codex` or `?agent=claude-code`.

1. Read `GET /auth/methods`. Keep its ordering and open a method by its ID.
2. Send `POST /auth/begin` with `{"method":"login"}`.
3. Open `AuthState.url` in the user's browser. When its `redirect_uri` points to
   loopback on a remote computer, first privately forward the callback's exact
   port to that computer. Keep the tunnel alive for the browser session; on iOS,
   use in-app Safari so opening the browser does not suspend the app's tunnel.
   If the port is occupied, report the conflict rather than changing the redirect
   URI. `code` is a code to **display/copy** for methods that provide one;
   `fields` are inputs to **collect** (Claude code handoff).
4. Poll `POST /auth/step` with `{"_flowId":"<flowId>"}`. Render returned `fields`
   and `sections` with the same controls/validation as other authentication forms.
   For Claude, submit `{"_flowId":"<flowId>","authorizationCode":"<code>"}`.
5. `complete` is terminal; refresh `/auth/status` and confirm `configured` before
   dismissing sign-in. Show `error` messages with a retry action.
6. On cancellation, send `{"_flowId":"<flowId>","_action":"cancel"}` to
   `/auth/step`. An older attempt ID cannot cancel or answer a newer flow.

`pending` and `needs_input` are both active states. Login lasts up to ten minutes;
the HTTP request lifetime does not control the native process. Concurrent opens
reuse the pending attempt. A native failure, timeout, or cancellation clears the
URL, display code, and fields. Changing to another auth method cancels that attempt.
Empty polls remain supported for older clients; cancellation requires a flow ID.

Keep the presentation alive while loading the URL/code and while the user visits
the browser. A readiness refresh must not dismiss its presenter. Transient poll
failures keep the same flow ID and retry; only explicit cancellation or a native
terminal state ends the attempt. Discard older status reads after authentication
changes so they cannot undo a completed sign-in or sign-out.

TypeScript exposes `auth.begin`, `auth.step`, `auth.poll`, `auth.cancel`, `auth.logout`, and
`auth.status`. The embedded Go SDK has the corresponding `Auth` methods. iOS uses
the same protocol for browser/code forms and native callback forwarding, including cancellation
when a sheet closes before a slow begin response arrives.

## Sign-out

`POST /auth/logout?agent=<harness>` returns `AuthStatus`. The capability
`authLogout` advertises support to older clients. It refuses with HTTP 409 while
this harness has running chats or installation, and blocks new turns during the
native sign-out operation. Codex uses `account/logout`; Claude uses
`claude auth logout`. API/cloud connections clear their harness-specific fields.

Explicit sign-out is persisted (`signedOut: true`), so credentials discovered in
a native config or environment cannot silently reconnect Mindwire after restart.
Chats, model settings and shared provider connections remain intact. Completing
a new auth method reconnects the harness. For native configurations, the methods
list offers `configFile` after sign-out; begin that method explicitly to verify
and reconnect an account already configured in the workspace. Fieldless methods
use `/auth/begin`; clients must not send an empty field submission instead.

## Credential ownership

Native CLIs persist and refresh subscription credentials in their own account
storage. The daemon does not read OAuth tokens out of those files or return them
to the phone. A successful login changes the daemon's selected method only after
the native account check succeeds. A pending/failed login preserves the selected
API/cloud connection.

Explicit subscription selection excludes old API keys, gateway URLs, and cloud
provider overrides from runs. Claude subscriptions connected by an older
`setup-token` flow continue to work; a successful new login replaces that token
selection with native credential management. Stored API/provider credentials
remain available for switching back and are not copied into subscription runs.

This requires both the daemon release containing browser login and the updated
Apple client with native callback forwarding. Other SDK clients must forward the
native loopback callback themselves when using a remote computer. CLI selection
remains governed by the harness catalog;
the tested Codex model/settings protocol is 0.155.1; Claude's subscription baseline
is 2.1.246. Model and reasoning controls are described in [SETTINGS.md](SETTINGS.md).

Native references:

- https://developers.openai.com/codex/auth
- https://developers.openai.com/codex/app-server
- https://code.claude.com/docs/en/authentication
