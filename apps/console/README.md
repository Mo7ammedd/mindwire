# Mindwire Console

Mindwire's hosted account and Cloud Computer management service. The browser portal manages account details, signed-in connections, notification devices, computer purchases, power and monthly subscriptions. Agent conversations, terminals and personal computers stay in the Mindwire app.

Console is not a self-hosted Mindwire client. Personal computers run the released `mindwired` binary independently and do not need Console or a Cloud subscription.

## Development

From the repository root, run `bun install` then `bun dev` to start the landing site (http://localhost:3000), account API, and SaaS console together. Open http://127.0.0.1:5174 and create a development account. Use `bun dev console` to start only the console and API. The API runs on port 8787 with SQLite; no Go compiler, Docker engine, agent runtime or provider credentials are required to open the portal. Set server-only reseller credentials to exercise Cloud purchases against an appropriate provider environment.

Run `bun --filter=@mindwire/console run check`, `run test`, and `run build` to validate changes. Cloud ownership, billing reconciliation, push migration and account management tests use a local provider fixture. Set `CLOUD_TEST_POSTGRES_URL` to run the Cloud tests against PostgreSQL.

For checkout browser tests, run `bunx playwright install chromium --only-shell`
then `bun run test:e2e` from `apps/console`. These test checkout recovery,
cancellation, errors and payment confirmation at desktop and iPhone widths with
intercepted APIs. They never use a real provider account or payment.

## Hosted deployment

The root `docker-compose.yml` builds the website and Console from source and starts PostgreSQL. Configure `.env.example` before deployment. Required production values are `AUTH_SECRET`, a separate `SECRETS_ENCRYPTION_KEY`, `POSTGRES_PASSWORD` (or `DATABASE_URL`) and the public `BASE_URL`. Preserve signing/encryption keys across releases. Cloud purchases also require server-only `OBLIEN_CLIENT_ID`, `OBLIEN_CLIENT_SECRET` and the webhook secret. Native runtime traffic connects directly to `workspace.oblien.com` using the owned computer's runtime token obtained through Console; no custom runtime hostname is required.

See [Cloud Computers](../web/content/docs/guides/cloud-computers.mdx) and [source deployment](../../docker/README.md). Firebase credentials remain outside the repository and build context; mount them read-only using the push Compose overlay.

The reseller credentials must belong to an Enterprise provider account with the
permissions needed for namespaces, billing and computers. The provider must also
allow the host of `BASE_URL` (normally `console.mindwire.sh`) in its own
`REDIRECT_ALLOWED_HOSTS`. Setting that variable on Console does not update the
provider's allowlist.

Cloud failures return a stable code and diagnostic reference. Find the matching
`[cloud] provider request failed` line in the Console server log for the upstream
operation, status and provider request reference. Credentials and response bodies
are excluded. For example, `billing_redirect_not_allowed` requires the provider's
return-host configuration; `reseller_enterprise_required` requires enabling the
provider account for resale. These are not fixed by resetting the Console database.
After correcting the configuration, use **Continue checkout** on the saved
computer. Its original purchase and idempotency key are reused.

Checkout recovery follows the tracked purchase flow used by OpenShip:

- Save the exact request before dispatch, and reuse it on **Resume checkout**.
- Inventory reads and automatic reconciliation never replay an unidentified
  checkout. A lost creation reply requires explicit resumption before cancellation.
- A documented rejection of the first attempt leaves a locally cancelable draft.
  A later rejection cannot discard an earlier uncertain payment.
- Read the scoped checkout status before resuming or canceling. Submitted payments
  show **Confirming payment** and cannot open another payment or be discarded.
- Persist the cancellation method and key before dispatch, then read the original
  checkout again. A lost cancellation reply is resolved from that status. The
  provider's advertised generic cancellation is preferred; a legacy capacity
  cancellation must match the same namespace and checkout.

The pinned Oblien SDK is 2.10.0, which already exposes checkout status. Its missing
generic cancellation endpoint and capability type stay inside the bounded provider
adapter, as in OpenShip. Confirmed paid capacity remains required for provisioning.

## Password recovery

The sign-in page links to `/forgot-password`; reset links return to `/reset-password`.
Console uses Better Auth's single-use, one-hour reset tokens and existing rate limits.
Resetting a password revokes that Mindwire account's sessions, so connected devices sign in again.
Recovery preserves the native `/device?user_code=…` approval destination when it is still valid.
Coding-agent credentials and personal-computer approvals are independent of this account flow.

Set server-only `SMTP_HOST`, `SMTP_PORT` (default `587`), `SMTP_USER`, `SMTP_PASSWORD`
and `SMTP_FROM`, then redeploy Console. Use a sender address verified with your email provider.
Port `587` requires STARTTLS; `465` uses implicit TLS. A trusted SMTP relay may omit
both username and password; partial credentials disable delivery. With no valid SMTP
configuration, recovery explicitly reports email as unavailable; other account features stay usable.
No credentials appear in public config or browser bundles.

Delivery runs in the background, keeping SMTP latency out of the recovery response.
Registered and unregistered addresses receive the same response. If delivery fails,
Console logs a fixed message without recipients, reset URLs or raw SMTP errors; inspect
your provider's delivery logs to diagnose credentials, sender approval or delivery issues.

## API boundaries

- `/api/account`: Better Auth sessions, profile, password and native device authorization.
- `/api/portal`: account-owned connection listing and revocation by opaque ID. Session tokens never appear in this listing.
- `/api/cloud`: owned computer inventory, purchases, checkout, subscription management and the constrained provider gateway.
- `/api/notifications`: notification registrations and send-only credentials.
- `/api/computer-directory/v1`: encrypted personal computer discovery, independent from browser login.

Console does not expose agent execution, chat, SSH or local Docker APIs. Existing database records are retained; this refactor does not erase stored account, Cloud, directory or notification data.

Native device approval shows the browser account with **Switch account** and **Sign out**.
Both use the existing browser-session sign-out action and retain the `/device?user_code=…`
URL for the next login. Merely opening the page verifies the code without browser credentials;
the authenticated verification that claims it runs only after an explicit Sign in or Cancel.
An already claimed request keeps Better Auth's ownership checks and cannot be reassigned.

## Visual theme

The portal and sign-in screens share the website palette in
[`packages/theme/tokens.css`](../../packages/theme/tokens.css). Console primitives
map their semantic tokens in `src/index.css`; feature CSS owns layout and
illustrations. The light default and stored `mw-theme` preference are applied
before paint. Both themes use the same rounded controls and Gellix typeface.

The account shell uses an inset desktop sidebar and an expandable mobile menu.
Check empty and populated accounts, error states, form focus, plan selection,
and confirmation dialogs at narrow widths. For visual review, intercept API
requests in a browser test with local fixtures; never use a real account change,
checkout, session revocation, or provider operation to test appearance.
