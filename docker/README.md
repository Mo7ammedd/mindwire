# Mindwire SaaS source deployment

The website and hosted account portal build from source. Mindwire does not publish Console or runtime container images to GHCR. Runtime distribution uses checksum-verified GitHub Release binaries; the TypeScript SDK continues to publish on npm.

## Deploy Mindwire's hosted service

Copy `.env.example` to `.env`, configure PostgreSQL, independent signing and encryption keys, the public Console origin and server-only provider credentials, then run:

```sh
docker compose up --build -d
```

The stack contains PostgreSQL, the website and the account portal. It has no agent daemon, SSH keys or Docker socket. Keep the loopback port bindings behind the production HTTPS proxy. Preserve the PostgreSQL volume and encryption keys between deployments. Firebase credentials mount read-only through `docker/docker-compose.push.yml` and never enter an image.

Local source images can be checked with:

```sh
docker build -f docker/console.Dockerfile -t mindwire-console:local .
docker build -f docker/web.Dockerfile -t mindwire-web:local .
```

These builds do not publish packages. Console builds independently of the SDK and Go daemon.

## Personal and Docker computers

Connect personal computers from the Mindwire app or SDK. The shared installer downloads the matching released runtime and verifies its checksum. A new Docker workspace uses the ordinary `node:24-bookworm` base image and installs the released daemon into its persistent home volume. Existing owned containers, including older runtime-image containers, stay discoverable and are not recreated by this change. The SDK's default Docker target also bootstraps a released binary into a standard Node container; custom images keep their own entrypoint and command.

No self-hosted Console installation is required. See the [destination guide](../apps/web/content/docs/guides/destinations.mdx) for runtime installation and [Cloud Computers](../apps/web/content/docs/guides/cloud-computers.mdx) for the hosted product.
