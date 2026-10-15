# Workspace controls

Mindwire uses the Oblien Swift SDK for cloud management and runtime operations. The
workspace page keeps projects, agents, service readiness and common tools in Overview;
Manage opens native pages for infrastructure controls. Individual settings live in
forms or detail pages instead of expanding the main workspace screen.

Touch and hold any workspace card for Open Workspace, New Project, Rename and Delete.
Paired computers also offer Reconnect and use local-only Remove from This iPhone.
The card menu and workspace toolbar share the same native dialogs and repository
operations. Creating from a card preselects that workspace; deletion waits for the
repository before closing the detail page.

## Ownership and reuse

`WorkspaceService.management` is an optional `WorkspaceManagementService`. The cloud
adapter implements it with `OblienKit`; infrastructure views read its feature set.
SSH hosts, Docker workspaces and paired computers continue to use their existing
files, terminal and daemon contracts. They do not acquire cloud disk, quota, public
network or billing controls merely because they support SSH.

| Area | Mobile controls |
| --- | --- |
| Resources and power | CPU, RAM, disk, apply mode, start/stop/restart, pause, hibernate/resume when supported |
| Storage | Attached/available disks, software, create/retain/copy/save/fork/grow, attach/detach/move/delete, durable progress and retry |
| Desktop | Image installation choices/status, preparation and restart, access switch, existing native SSH/VNC viewer |
| Workloads | Create with runtime/environment/directory/restart/log settings, edit name/restart policy, start/stop/delete, live process metrics and logs |
| Network | Outbound internet and IP, private workspace links, ingress/egress policy, managed or custom outbound proxy |
| Public access | Public access switch, exposed ports and slugs, custom domain, DNS records/verification and SSL renewal |
| Access | SSH availability, connection/copy actions, password/public key, runtime API access and token rotation |
| Settings | Name, slug, logo, workspace mode, restart/TTL/idle policy, reinstall/delete with native confirmations |
| Backups | List/create/delete file archives, explicit include/exclude paths; hibernation remains a separate power action |

The SDK also exposes account services (namespaces, pages/routes, edge proxies/tunnels,
domains, webhooks, billing, analytics, CDN and notifications). They are available to
Swift clients without turning a workspace page into an account dashboard. The SDK's
`docs/TypeScriptCoverage.md` records the complete TypeScript mapping and native
boundaries.

`apps/apple/project.yml` pins the merged SDK commit from GitHub. Regenerating the
Xcode project uses that remote revision; it does not require a sibling SDK checkout.
The SDK update was merged in [oblien/swift-sdk#1](https://github.com/oblien/swift-sdk/pull/1).

## State and operations

- The repository retains each `WorkspaceModel` and its management model across
  navigation. Successful reads have a five-minute cache. Manual refresh bypasses it;
  refresh failures preserve the last good values and show the failure.
- Mutations belong to that shared model, not a sheet. Repeated identical commands join
  the same task; conflicting commands are blocked until the active operation finishes. A
  closed form does not cancel accepted work.
- Mutations invalidate affected reads before refreshing. Generation checks prevent an
  older in-flight response from overwriting newer state. Sign-out disposes provider
  state and invalidates cached runtime credentials.
- Disk changes carry an idempotency key. An uncertain retry keeps the same key. The
  API owns disk operation IDs, permissions, atomic attachment checks and installation
  state; the app resumes polling discovered operations after reopening.
- Creation returns as soon as the workspace is accepted. The list can show creation
  immediately; the persisted preparation queue follows SDK readiness before preparing
  Mindwire. Failures expose Retry Creation instead of a misleading service error.
- The image catalog preserves presets, VM defaults and resource minimums. A retained
  root uses its saved boot definition. Additional disks retain their namespace,
  runtime target, read-only flag and mount path. The same creation flow is used from
  disk details and the Workspaces tab.

## Live data

The SDK decodes SSE and websocket protocols. Workload metrics use one subscription
per visible workspace, shared across list and detail transitions. Backgrounding or
leaving the pages releases it; reopening or manual refresh reconnects it. Old
measurements are never presented as live after the connection ends.

Log following subscribes before reading history and reconciles the boundary in the
SDK. The mobile list keeps at most 2,000 lines/1 MiB and provides pause/resume. It does
not implement a second history/live merge. Desktop keeps the existing native viewer
and SSH transport, using SDK installation and connection-grant APIs.

## Verification

SDK contract tests cover nullable patches, casing, credentials, retries, idempotency,
streams, transfer framing and TypeScript surface drift. Opt-in checks create and
remove disposable workspace/disk fixtures and verify runtime files/search/transfers,
native terminal/watcher events, workloads/logs, access, desktop preparation, network
and disk operations. Account checks exercise read groups, not destructive billing or
account mutations.

`WorkspaceManagementTests` covers mobile cache invalidation, shared operations,
durable progress, creation/presets/storage, metrics subscription ownership and native
screen snapshots. Workspace availability, service readiness, sign-in, project-start
and native desktop regression suites cover the adjacent flows.

Some Oblien workspace runtime images reject workload log retention/clear with HTTP
409 until that runtime is upgraded. The SDK exposes the APIs and the app displays the
server's capability error. This does not require a Mindwire daemon protocol change.

README and Markdown files open in a read-only preview using the same MarkdownUI
parser, text selection, tables and code highlighting as chat responses. Show Source
switches to the existing editor without rereading the file; Edit uses the source
buffer and the normal Save/Cancel flow. Relative links resolve from the document's
folder and reuse the workspace's file browser and image preview. Line citations
open source directly so their requested line remains visible.
