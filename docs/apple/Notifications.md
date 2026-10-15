# Mobile Push (FCM) — Internal Guide (Oblien App ONLY)

Audience: the **Oblien mobile app**. These endpoints register a device's real
FCM token under the signed-in user and let the app check its registration
status.

> Scope boundary — read this:
> The `/notifications` router carries **two unrelated things**. This document is
> **only** the device half, which is the mobile app's concern:
>
> | Concern | Endpoints | Who uses it | Docs |
> |---------|-----------|-------------|------|
> | **Mobile FCM devices** | `/notifications/devices*` | **Oblien app only** (user session) | **this file** |
> | Workspace virtual send tokens | `/notifications/tokens*`, `/notifications/send` | Dashboard / developers / in-workspace code | (dashboard / developer docs) |
>
> Do **not** document or expose the device endpoints in dashboard/developer-facing
> docs. The virtual **send tokens** are the workspace-level thing; the device
> registry is app-internal.

Base URL: `https://api.oblien.com`

---

## 1. How it fits together

```
 Oblien app ──register device(fcm_token)──▶  /notifications/devices   (this doc)
                                                     │ stores real FCM token per user
 in-workspace code ──send(title,body)──▶ /notifications/send          (send token, NOT this doc)
                                                     │ resolves owner's active devices
                                                     ▼
                                                    FCM ──▶ device
```

The app only ever deals with **device registration + status**. The real FCM
token lives server-side; it is never handed back to workspaces. Delivery is
driven by separate per-workspace **send tokens** (out of scope here).

---

## 2. Authentication

Use the **user's session bearer token** — the same JWT from `AUTH_API.md`:

```
Authorization: Bearer <user_session_jwt>
```

Device endpoints run behind `clientAuthMiddleware` + `requireScope('admin')`.
For the mobile app this means a normal logged-in **user session** (the account
owner, no API-key scope) is accepted. Delegated **namespace/workspace-scoped**
credentials are **rejected** with `403 scope_denied` — devices are a user-global
resource and must only be managed by the account owner, deliberately separate
from the workspace-level send tokens.

All device data is scoped to the authenticated `user_id`; one user can never see
or touch another user's devices.

---

## 3. Endpoints

### 3.1 Register / refresh a device — `POST /notifications/devices`

Call this on first launch after notification permission is granted, and again
whenever the FCM token rotates (FCM `onTokenRefresh`). It is an **upsert** keyed
on `(user_id, device_id)`: the same `device_id` updates its row in place and
**re-activates** a previously revoked device.

**Request:**
```json
{
  "device_id": "stable-app-install-id",     // required, ≤255 chars, app-generated & stable per install
  "fcm_token": "<current FCM registration token>",  // required, ≤512 chars
  "platform": "ios",                          // "ios" | "android" | "web" (defaults to "android" if omitted/invalid)
  "device_info": { "model": "Pixel 8", "os": "14", "app_version": "1.2.0" }  // optional object
}
```

**Success — `201`:**
```json
{
  "success": true,
  "device": {
    "id": 123,
    "device_id": "stable-app-install-id",
    "platform": "ios",
    "device_info": { "model": "Pixel 8", "os": "14", "app_version": "1.2.0" },
    "status": "active",
    "last_seen_at": "2026-06-23T10:00:00.000Z",
    "token_validation": "…"        // present only if FCM validation was skipped/soft (see note)
  }
}
```

**FCM validation on register:** the token is dry-run validated with FCM *before*
storing. A token FCM **definitively rejects** → `400 invalid_device_token`
`{ "details": { "reason": "…" } }` (the app should fetch a fresh FCM token and
retry). If FCM is unconfigured or has a transient hiccup, registration **fails
open** (soft) and `token_validation` is included so you know it wasn't hard-verified.

**Errors:** `400 validation_error` (missing/oversized `device_id`/`fcm_token`, or
`device_info` not an object), `400 invalid_device_token`, `401 unauthorized`,
`429 rate_limit` (writes limited to 30/min).

`device_id` guidance: use a **stable per-install identifier** you control (e.g. a
UUID generated once and persisted in secure storage). Do **not** use the FCM
token as the `device_id` — the FCM token rotates; `device_id` must not.

---

### 3.2 Check device status — `GET /notifications/devices/status?device_id=<id>`

Cheap single-device lookup. Use it on launch/foreground to confirm the device is
still `active` before relying on push. A device flips to `revoked` automatically
if FCM reports its token unregistered during a send — when that happens, the app
should re-register (§3.1) to get back to `active`.

**Request:**
```
GET /notifications/devices/status?device_id=stable-app-install-id
Authorization: Bearer <user_session_jwt>
```

**Responses — `200`:**
```json
{ "success": true, "registered": false }
```
```json
{
  "success": true,
  "registered": true,
  "id": 123,
  "device_id": "stable-app-install-id",
  "platform": "ios",
  "device_info": { "...": "…" },
  "status": "active",                 // "active" | "revoked"
  "last_seen_at": "2026-06-23T10:00:00.000Z",
  "created_at": "2026-06-01T09:00:00.000Z"
}
```

**Errors:** `400 validation_error` (missing `device_id`), `401 unauthorized`.

App logic:
- `registered:false` or `status:"revoked"` → re-register before trusting push.
- `registered:true` && `status:"active"` → good.

---

### 3.3 List the user's devices — `GET /notifications/devices`

```json
{
  "success": true,
  "devices": [
    { "id": 123, "device_id": "…", "platform": "ios", "device_info": { … },
      "status": "active", "last_seen_at": "…", "created_at": "…" }
  ]
}
```
Useful for a "manage devices / logged-in devices" screen. Ordered by most
recently seen.

---

### 3.4 Remove a device — `DELETE /notifications/devices/:id`

`:id` is the **numeric row id** (`device.id` from register/list/status), not the
`device_id` string. Call on logout or when the user removes a device.

```json
{ "success": true }
```
**Errors:** `400 invalid_id`, `401 unauthorized`.

> On logout, also remember to revoke/replace the auth token (see `AUTH_API.md`).
> Removing the device here only stops push to it; it does not end the session.

---

## 4. Recommended app lifecycle

1. **After login + notification permission granted:** obtain the FCM token →
   `POST /notifications/devices` with your stable `device_id`.
2. **On FCM `onTokenRefresh`:** call `POST /notifications/devices` again (same
   `device_id`, new `fcm_token`) — it upserts.
3. **On app launch / foreground:** `GET /notifications/devices/status?device_id=…`.
   If `registered:false` or `status:"revoked"`, re-register.
4. **On logout / "remove this device":** `DELETE /notifications/devices/:id`.

## 5. Notes

- One `Authorization: Bearer <user jwt>` (from `AUTH_API.md`) authenticates all
  of these — there is no separate FCM credential for the app.
- The real `fcm_token` is write-only from the client's perspective: it is never
  returned by any endpoint. Treat it as a secret in transit (HTTPS only).
- Sending notifications is **not** an app responsibility and is not in this doc;
  it is driven server-side via per-workspace send tokens.

## Mindwire integration and verification

The app bundle is `com.oblien.mindwire`; its embedded notification extension is
`com.oblien.mindwire.notifyservice`. `GoogleService-Info.plist` must identify that
same app, with APNs credentials configured for it in Firebase. Signing uses the
project's development team and the app's push entitlement.

Firebase's APNs key ID and Apple team ID must match the uploaded `.p8` key, and the
credential must support the delivery environment: sandbox for development builds,
production for TestFlight/App Store builds. The key's display name can contain an
old app name; a topic-specific key must allow the current bundle ID.
`messaging/third-party-auth-error` / `Invalid APNs credential` means Firebase could
not authenticate to Apple. Correct that configuration before retrying; changing
the App Store listing does not repair APNs authentication.

Harness avatars belong to the app. The daemon sends the harness ID in `data.agent`;
the app and notification extension share `AgentBrand` and the existing bundled
artwork. The original SVGs are copied unchanged from the daemon repository into
`apps/apple/AgentArtwork`; vector PDFs exported from them avoid Xcode's SVG path
rendering errors. See that directory's README to refresh the assets. The
extension preserves the logos' transparent backgrounds, rasterizes
them at full size, awaits an incoming
`INSendMessageIntent` donation, then updates the notification. iOS draws the small
Mindwire badge. Keep `INSendMessageIntent` in the app's `NSUserActivityTypes` and
the Communication Notifications entitlement enabled; otherwise delivery can work
while the banner falls back to the full app icon.

`LivePushService` reconciles registration after login, on foreground, and after
APNs/FCM token callbacks. It shares concurrent registrations, replaces definitively
rejected FCM tokens, and unregisters before clearing the account session. Registered
tokens are never printed. Device metadata includes the current bundle identifier.

SSH workspaces and paired computers work without signing in, but the current Oblien
push registry requires a signed-in account. Reinstalling or losing that account
session can therefore leave chat working while the new APNs/FCM token cannot be
registered. iOS permission alone does not establish delivery. Notification Settings
and agent/chat notification preferences show **Device: Allowed** separately from
**Delivery: Sign in required**, with the existing hosted sign-in flow available there.

Fresh signed-out installations see an optional native sheet explaining completion,
question and error alerts for all workspace types. **Not now** (including a swipe
dismissal) suppresses further reminders; **Remind me later** waits seven days. The
choice is device-local, does not mute agents, and does not change iCloud backup
settings. The sheet never interrupts a chat, pairing or another modal, and multiple
windows share one presentation claim.

Phone registration starts independently of workspace inventory. Permission and
registration callers share an owned task, including account changes during a request.
Failed registration or a missing APNs/FCM token retries while foregrounded at 5, 15,
60 and then 300 seconds; a recovered network retries immediately. Successful
registration cancels retries and reconciles connected daemons. Healthy registrations
have no polling timer. Workspace provisioning also shares foreground/registration
reconciliation and retains its existing retry intervals.

Workspace delivery uses a separate send credential. `DaemonSession` provisions
`PUT /notify/config` with `format: "push"` and verifies the saved configuration.
This format requires a daemon release containing push relay support; older daemons
only send raw notification JSON. A failed setup is retried independently of agent
installation. Send credentials are isolated by account, workspace, and installation
and checked for revocation before reuse.

Paired computers and SSH/container workspaces follow the same setup. Their local
workspace IDs are channels, not Oblien workspace IDs, so they use generic send-only
credentials from the signed-in notification account. Account sessions and FCM
device tokens never go to the computer. Cloud workspaces retain their workspace-bound
credentials. Push setup failure does not block chat or trigger a daemon reinstall.

Run `PushNotificationTests` and `WorkspaceNotificationTests` for lifecycle and
recovery checks. For actual delivery, run `PushDeliveryLiveTests` on a signed-in,
unlocked physical iPhone with `MINDWIRE_LIVE_PUSH=1`. It creates a temporary send
credential pinned to that phone and writes a handoff to the app's
`Library/Caches/mindwire-push-check.json`. Copy that file to a private local temporary
file, then run the daemon's `TestPushDeliveryLive` with `MINDWIRE_LIVE_PUSH_FILE`
pointing to it. The daemon sends labelled completion, approval, and error checks;
the app asserts actual APNs receipt and chat routing. The test deletes the temporary
credential afterward. Delete the local handoff copy as well. A device registration
or HTTP 200 without delivered notifications does not establish working push delivery.
Set `MINDWIRE_LIVE_PUSH_REMOTE=1` for the paired-computer check. It first provisions
the saved computer over SSH and verifies its actual push configuration, then checks
generic-token delivery to the same iPhone.
