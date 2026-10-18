# Mindwire Console

Mindwire's hosted account and Cloud Computer management service. The browser portal manages account details, signed-in connections, notification devices, computer purchases, power and monthly subscriptions. Agent conversations, terminals and personal computers stay in the Mindwire app.

Console is not a self-hosted Mindwire client. Personal computers run the released `mindwired` binary independently and do not need Console or a Cloud subscription.

## Development

From the repository root, run `bun install` then `bun dev`. Open http://127.0.0.1:5174 and create a development account. The API runs on port 8787 with SQLite; no Go compiler, Docker engine, agent runtime or provider credentials are required to open the portal. Set server-only reseller credentials to exercise Cloud purchases against an appropriate provider environment.

Run `bun --filter=@mindwire/console run check`, `run test`, and `run build` to validate changes. Cloud ownership, billing reconciliation, push migration and account management tests use a local provider fixture. Set `CLOUD_TEST_POSTGRES_URL` to run the Cloud tests against PostgreSQL.

## Hosted deployment

The root `docker-compose.yml` builds the website and Console from source and starts PostgreSQL. Configure `.env.example` before deployment. Required production values are `AUTH_SECRET`, a separate `SECRETS_ENCRYPTION_KEY`, `POSTGRES_PASSWORD` (or `DATABASE_URL`) and the public `BASE_URL`. Preserve signing/encryption keys across releases. Cloud purchases also require server-only `OBLIEN_CLIENT_ID`, `OBLIEN_CLIENT_SECRET` and the webhook secret; configure `computers.mindwire.sh` with the runtime gateway before releasing the native app.

See [Cloud Computers](../web/content/docs/guides/cloud-computers.mdx) and [source deployment](../../docker/README.md). Firebase credentials remain outside the repository and build context; mount them read-only using the push Compose overlay.

## API boundaries

- `/api/account`: Better Auth sessions, profile, password and native device authorization.
- `/api/portal`: account-owned connection listing and revocation by opaque ID. Session tokens never appear in this listing.
- `/api/cloud`: owned computer inventory, purchases, checkout, subscription management and the constrained provider gateway.
- `/api/notifications`: notification registrations and send-only credentials.
- `/api/computer-directory/v1`: encrypted personal computer discovery, independent from browser login.

Console does not expose agent execution, chat, SSH or local Docker APIs. Existing database records are retained; this refactor does not erase stored account, Cloud, directory or notification data.
