# Mindwire

**Your personal assistant. Your computer. Your choice of agent.**

Mindwire brings agent harnesses such as Codex, Claude Code, Grok Build, and OpenCode into one
experience. Ask for an outcome, follow the work, answer a question when needed, and pick up the
result from your phone or browser. Run the work on your computer, your server, or a cloud workspace.

Use the same foundation for everyday tasks and software development: organize files, process data,
prepare documents, automate a workflow, or build and review code. What an assistant can do depends
on the selected harness, its tools, the workspace, and the access you grant it.

[Get started](https://mindwire.sh/get-started) · [Documentation](https://mindwire.sh/docs) ·
[Web console](https://console.mindwire.sh) · [Contributing](CONTRIBUTING.md)

## One ecosystem

- **Apple app:** a native SwiftUI client for conversations, files, Git, terminals, approvals,
  notifications, and supported desktop sessions. iPhone and iPad are implemented today.
- **Web console:** manage workspaces and work with agents from a browser, self-hosted or through
  the managed service.
- **Runtime:** `mindwired` runs alongside the native harness, owns task execution, and exposes
  a shared HTTP and event API. Work can continue when a client disconnects.
- **SDKs:** TypeScript and Go interfaces for building tools and products on the same runtime.
- **Your infrastructure:** use a paired computer, SSH host, Docker workspace, or Oblien cloud
  workspace. Model access follows the selected provider's supported authentication and limits.

A harness handles its own agent loop and native state. Mindwire connects that execution to clients,
workspace tools, and durable task controls. Switching harnesses does not make their native sessions,
permissions, or capabilities interchangeable.

## Current support and direction

| Surface | Status |
| --- | --- |
| iPhone and iPad | Native client in `apps/apple`, built with Xcode 26+ |
| Browser | Console and product/documentation site |
| Runtime | macOS, Linux, and supported Windows paths; capability-dependent |
| Native Mac app | Planned in the shared Apple project; no macOS target yet |
| visionOS and other Apple platforms | Planned; platform adapters and validation still required |
| Personal assistant workflows | Use the installed harness's files, tools, and execution capabilities |

The consumer experience is evolving toward simpler setup and reusable everyday workflows.
Coding remains a first-class use case. This repository does not claim that every harness can
operate every desktop application or complete every task.

## Repository layout

```text
apps/
  apple/          SwiftUI app, Apple tests, artwork, and capture tools
  console/        Browser client and authenticated control plane
  web/            Product website and developer documentation
  protocol-lab/   Small HTTP/SSE developer test client
packages/
  daemon/         Go runtime, native Go SDK, adapters, and protocol contracts
  sdk/            Published TypeScript SDK and CLI (`mindwire`)
deploy/
  docker/         Runtime, console, and website images; self-hosted Compose
scripts/          Shared development, release, and Apple artwork tooling
docs/
  apple/          Apple implementation and validation notes
```

`apps/apple` is the home for shared Apple development. Platform-specific UI and operating-system
integrations can be added there without creating another copy of the runtime or feature logic.
See [the monorepo migration](docs/monorepo.md) for old paths and Go import changes.

## Run locally

Requirements: Go matching [`packages/daemon/go.mod`](packages/daemon/go.mod), Bun 1.3.1,
and the harness you want to use. The Apple app also needs Xcode 26+ and XcodeGen.

```bash
bun install
bun dev                  # runtime + console, browser at http://127.0.0.1:5174
bun run dev:web          # product website and docs
bun run dev:daemon       # runtime only
bun run dev:protocol     # runtime + protocol lab at http://127.0.0.1:5175
```

Open the Apple app:

```bash
bun run apple:generate
open apps/apple/Mindwire.xcodeproj
```

For a computer connection, install the released CLI and follow its pairing flow:

```bash
npm install -g mindwire
mindwire connect
```

Read the [Apple development guide](apps/apple/README.md), [runtime guide](packages/daemon/README.md),
and [container deployment guide](deploy/docker/README.md) for the relevant setup.

## Build on Mindwire

```ts
import { Mindwire } from "mindwire";

const assistant = new Mindwire({ agent: "claude-code" });
const run = await assistant.turn({
  chatId: "weekly-report",
  message: "Read the CSV files in this workspace and write a weekly summary to report.md.",
});

for await (const event of run) {
  if (event.type === "text") process.stdout.write(event.text ?? "");
}
```

Select another supported harness using `agent`. Use the SDK's local, remote, SSH, Docker,
or Oblien targets to choose where execution belongs. The [SDK guide](packages/sdk/README.md)
and [API documentation](https://mindwire.sh/docs) describe capability and authentication differences.

## Checks

```bash
bun run build:daemon
bun run test:daemon
bun run typecheck
bun scripts/release.ts --dry-run patch
bun run test
bun run build
```

Provider-backed tests require an explicit opt-in (`CLAUDE_LIVE=1`, `CODEX_LIVE=1`, or
`OPENCODE_LIVE=1`) and configured provider access.

Apple build and test commands live in [`apps/apple/README.md`](apps/apple/README.md).
Container images build from the repository root. Published npm names, binary names, GitHub release
URLs, and container image names remain unchanged by the monorepo move.

## Source and licensing

Mindwire supports local and self-hosted use. Managed cloud infrastructure is optional; resource and
model usage follow their respective service terms. Future consumer subscription packaging is separate
from the current infrastructure offers.

This monorepo contains separately licensed components:

- Runtime, SDKs, console, website, and deployment tooling: [Apache-2.0](LICENSE).
- Apple client: [source-available](apps/apple/LICENSE). Inspection and private personal builds
  are allowed; redistribution, rebranding, and publishing derivative apps require written
  permission. Using the official app for work is allowed by these source-code terms.
- Protocol lab, Apple notes, and Apple artwork/capture tooling outside `apps/apple`:
  [AGPL-3.0](apps/protocol-lab/LICENSE).

Third-party material retains its own licenses and notices. See [LICENSING.md](LICENSING.md)
for component boundaries, prior license grants, and contribution terms.
