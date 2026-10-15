# Mindwire protocol lab

A small React/Vite client for testing the runtime's HTTP and SSE protocol. The full user-facing
browser app is [`apps/console`](../console); this lab preserves the former pocket-agent test UI.

From the repository root:

```bash
bun install
bun run dev:protocol
```

This starts the local runtime and the lab at `http://127.0.0.1:5175`. Enter the daemon URL
and your local development bearer token in the lab. The shared launcher owns the daemon process;
closing it stops the development server. Agent tasks and authentication use the selected harness.

```bash
bun run build:protocol
```

Licensed under [AGPL-3.0](LICENSE), retained from the original application repository.
