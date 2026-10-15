# Container deployment

Deployment assets live here rather than in the SDK package workspace. Run all commands from the
repository root. Image names and release tags remain compatible with existing installations.

| Image | Purpose |
| --- | --- |
| `ghcr.io/oblien/mindwire-runtime` | Agent workspace with `mindwired` and the pinned supported harnesses |
| `ghcr.io/oblien/mindwire-console` | Browser application and authenticated control plane |
| `web.Dockerfile` | Product website and developer documentation, built from source |

## Private self-hosted installation

```bash
cp docker/.env.example docker/.env
# Replace the example credentials and choose a released MINDWIRE_VERSION.
docker compose --env-file docker/.env \
  -f docker/docker-compose.selfhost.yml config --quiet
docker compose --env-file docker/.env \
  -f docker/docker-compose.selfhost.yml up -d
```

The console binds to loopback by default. Put a TLS reverse proxy in front when remote access is
needed and set `BASE_URL` to that origin. The runtime has no published host port; the console reaches
it over the Compose network with its bearer token. No Docker socket is mounted by this stack.

The runtime runs as `node`. Harness credentials, task state, and workspace files persist in
`daemon_home` at `/home/node`, preserving the existing image and volume layout. Console accounts
persist in `console_data`. Removing containers preserves these named volumes.
`docker compose down -v` deletes them.

The image supplies harness binaries, not model access. Configure the selected provider through the
console using its supported authentication. Existing provider limits and charges still apply.

## Build from this checkout

```bash
docker build -f docker/runtime.Dockerfile -t mindwire-runtime:dev .
docker build -f docker/console.Dockerfile -t mindwire-console:dev .
docker build -f docker/web.Dockerfile -t mindwire-web:dev .
```

The runtime build reads the Go module from `packages/daemon`. Console and website builds use the
root Bun lockfile. Apple sources, screenshots, local environment files, dependencies, and build output
are excluded from the image build context. The website uses the same pinned Bun version as CI.

## Managed cloud stack

The root `docker-compose.yml` builds the website and multi-user console with PostgreSQL. It does not
run agents inside the control plane or mount a host Docker socket. Runtime placement remains selected
per workspace. Follow `.env.example` for the cloud stack's settings; the self-hosted environment file
above is separate.

## Upgrades

Pin both self-hosted images to the same tested release, back up the persistent volumes, update
`MINDWIRE_VERSION`, then pull and recreate the stack. Published runtime image names and GitHub binary
asset names are unchanged by the monorepo restructure. Compatibility checks remain in the runtime.
