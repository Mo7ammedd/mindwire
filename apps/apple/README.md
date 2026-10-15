# Mindwire — Apple app

Native **SwiftUI** client for Mindwire, built for **iOS 26 and macOS 26** with Apple's
**Liquid Glass** design language and native components throughout (system `TabView`
glass bar, glass toolbars, `.buttonStyle(.glass/.glassProminent)`, `NavigationStack`,
sheets). Clean, protocol-oriented architecture using the Observation framework.

This is the shared home for the Apple clients. iPhone and iPad use the mobile layout. The Mac build
uses Mac Catalyst's Mac interface idiom with a dedicated desktop SwiftUI shell. Chat, drafts,
connections, terminal, editor, and developer tools share the same implementation. visionOS support
is planned.
The runtime is in [`packages/daemon`](../../packages/daemon) in this same repository.

Original Mindwire material in this component is [source-available](LICENSE), not open source.
You may inspect it and make private local builds for your own use, including your own work.
Redistribution, rebranding, commercial exploitation of the client code, and publishing derivative
apps require prior written permission, whether free or paid. Official app use for work is allowed
by these source-code terms. Third-party material retains its own licenses and notices; see
[third-party notices](THIRD_PARTY_NOTICES.md) and the root [component license map](../../LICENSING.md).
Apple contributions carry the explicit copyright grant in section 5 of the license.

## Requirements

- **Xcode 26 or newer** (the Liquid Glass APIs — `glassEffect`, `GlassEffectContainer`,
  `.buttonStyle(.glass)`, the glass `TabView` — are in the iOS 26 SDK).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the
  `.xcodeproj` is generated from `project.yml` and is git-ignored.
- **OblienKit** is fetched from [oblien/swift-sdk](https://github.com/oblien/swift-sdk)
  at the merged revision pinned in `project.yml`. No separate SDK checkout is needed.

## Build & run

```bash
cd apps/apple
xcodegen generate
open Mindwire.xcodeproj
# then ⌘R on an iOS 26 simulator or device.
# CLI:
xcodebuild -scheme Mindwire \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=26' build
# Mac desktop:
xcodebuild -scheme MindwireMac \
  -destination 'platform=macOS,variant=Mac Catalyst' build
```

> Liquid Glass's specular highlights and motion render fully only on **physical
> hardware** (the simulator approximates them).

### Mac interface

The Mac opens into chat, with a conversation sidebar, search, and a glass composer. Choose the
computer/project context from the composer; existing computer pairing and subscription setup
remain available through Computers. The Developer tools setting in Settings or the sidebar menu reveals
Projects and Agent settings. Files, Git, ports, terminal, and remote desktop use the existing
workspace and project screens.

`⌘N` starts a chat, `⌘F` focuses conversation search, and `⌘,` opens Settings. Return sends;
Shift-Return inserts a new line. Windows have independent navigation and share the existing
bounded chat cache and draft store. A welcome-screen message is handed to the normal chat
composer after the daemon acknowledges creating the conversation.

On Mac, pairing accepts a pasted link or a QR-code image through the system file picker.

[Dark preview](artifacts/mac-ui/welcome-dark.png) · [Light preview](artifacts/mac-ui/conversation-light.png)

## Architecture

```
Mindwire/
├─ App/            @main, MainScene (glass TabView), AppModel
├─ Models/         Pure Codable domain types + constants (mirror the TS wire shapes)
├─ Services/
│  ├─ Ports/       Backend · AgentService · WorkspaceService · RuntimeProvisioner · AgentTransport
│  ├─ Cloud/       Oblien adapter — thin wrapper over the OblienKit SDK
│  ├─ Mock/        in-memory adapters + seed data (the default backend)
│  ├─ Daemon/      DaemonSchema (config-form resolution)
│  └─ Backends/    BackendFactory (runtime → backend)
├─ Stores/         JSONListStore<T> (UserDefaults) · Keychain · AgentConfigStore · AppPrefs
├─ Features/       Agents · Chat · Projects · Servers · Workspace · Settings
│                  (each: native Views + an @Observable ViewModel where async lives)
├─ DesignSystem/   Palette · Typography · Glass helpers · components · backgrounds · icons
├─ Navigation/     Per-tab Route enums + NavigationStack wiring
├─ Localization/   Flat `en` catalog + t() interpolation
└─ Resources/      Assets.xcassets (colors + brand/agent/provider vectors) · Info.plist
```

### State & data

The app opens directly to Projects, including on a fresh install. Oblien sign-in
is available from account settings and cloud features; it is not a launch requirement.

- **Personal computers:** QR pairing creates a normal workspace over pinned native
  SSH, directly or inside WSS. `ComputerWorkspaceService` implements the same workspace
  port; `ComputerDaemonChannel` reuses HTTP/SSE, and `DaemonTerminalProvider` feeds the
  existing SwiftTerm view from daemon-owned PTYs. The computer's CLI owns installation
  and idle updates. See [Personal computers](../../docs/apple/PersonalComputers.md) for the
  connection design, verification and rollout status.
- **Observation** (`@Observable`) for view state and view models; shared services
  injected via `@Environment` (`\.stores`, `AppModel`).
- **Workspace authority:** Oblien owns cloud workspace inventory. Each workspace's
  daemon owns saved agent profiles, projects and chat links in `~/.mindwire/workspace.db`.
  Harness-native settings/history remain native. Mindwire-managed credentials and
  environment injection use the existing daemon auth adapters and credential store.
- **Project operations:** creation, folder validation, cloning, folder deletion, cancellation and
  recovery run in the daemon (`projectOperationsVersion: 1`). `ProjectCreationModel`
  checks compatibility before acquiring credentials and returns on the daemon's acknowledgement.
  A workspace without agents continues to the shared agent picker, CLI preparation and sign-in
  flow; cloning continues independently. Finishing setup opens the new project with that agent
  when its metadata is ready. Users can skip setup, and workspaces with existing agents skip it
  automatically. Pending projects stay in Projects, where the same row shows creation progress
  and becomes a normal project when metadata arrives. Workspace detail uses the same rows. Operation details observe
  full snapshots over the shared proxy/SSE or SSH/polling transport; closing a screen detaches
  observation. Logs start collapsed. GitHub adapters provide
  write-only clone authorization; iOS builds no clone command and guesses no outcome
  from filesystem listings. The daemon stores operations and project metadata in
  the same SQLite database and never embeds credentials in a Git origin.
  Folder deletion submits the confirmed record revision to the daemon; running chats
  block it before files are touched. Removal from the project list only deletes
  membership, and both removal modes retain native harness transcripts.
- **GitHub access:** independent PAT/SSH/GitHub CLI connections work without an Oblien
  login. iOS owns account management and browsing. Projects can select a connection or
  inherit the workspace default. Credentials are supplied for a run/operation unless
  the user chooses to save access on the workspace. Existing local Git commands stay
  on `ExecGitService`; authenticated fetch/pull/push and agent Git use the daemon's
  helper (`gitAccessVersion: 1`). See [GitHubAccess.md](../../docs/apple/GitHubAccess.md).
- **Source Control:** working changes, the Commit sheet, and commit history share file rows
  and the native diff editor. History reads immutable Git objects through the workspace exec
  transport and pins its tip during pagination. Registered-project writes use durable daemon
  operations: version 2 adds branches; version 3 adds structured identity errors and retains the
  older combined commit API. Author configuration now uses the independent `gitIdentityVersion: 1`
  settings API. Save Author never commits, and supports repository overrides, workspace defaults,
  and a shared default for every connected workspace. Pending default deliveries survive app
  restarts, respect daemon acknowledgements, and resume from the app lifecycle. See
  [GitAuthorSettings.md](../../docs/apple/GitAuthorSettings.md). Older services explain that an update is required.
  Version 4 adds Restore This Version from commit details. It captures the current HEAD and branch,
  requires a clean working tree, and restores files as staged changes without rewriting history or
  committing. Older services show an update requirement. The Sync Repository sheet shares durable
  Push/Pull/Fetch progress with Source Control; detailed output stays collapsed.
  Run `bash scripts/check-git-history.sh` on macOS for real-Git adapter checks in isolated temporary
  repositories; `GitReviewTests` and `GitOperationTests` cover native rendering and operation recovery.
- **Device cache:** `WorkspaceDataRepository` displays the persisted `mindwire:*`
  lists immediately, imports legacy IDs once, and applies full snapshots and
  revision deltas. Saves commit on the workspace before changing the cache.
  Acknowledged operation snapshots are persisted too, with bounded logs and the registry identity;
  cold/offline progress is labeled as last known until reconnection. Sequence checks prevent old
  snapshots from rolling progress back, and completed operations never recreate deleted projects.
  The active app checks deltas every five seconds and inventory every minute.
  An authoritative workspace deletion prunes its cached agents, projects, chats and operations;
  network/auth failures preserve them. Last-use ordering stays device-local.
- **Workspace daemon status:** every workspace exposes its installed version, compatibility and
  update action without requiring an agent. `DaemonWorkCoordinator` shares update jobs with agent
  screens and caches last-known versions; connectivity must be checked again after launch.
  Both entry points check active projects, chats and CLI installations before replacement, then
  verify the running version. Latest-release metadata uses the existing shared `ReleaseCatalog`.
  Install progress distinguishes download, upload and startup. Linux/macOS launchers create a new
  session and ignore hangup directly; macOS `nohup` can fail after detachment in headless images.
  Startup failures report the child exit status and captured log together.
- **Migration:** the daemon advertises `workspaceMetadataVersion: 1`. Existing
  agent/chat metadata can retain legacy behavior until the workspace is upgraded.
  Project writes require the updated daemon and never fall back to local ownership.
  A migrated cache never becomes authoritative again. Upgrade the daemon and app
  to enable workspace ownership; the first successful sync preserves all existing IDs.
- **Connections and secrets:** SSH connection records remain local. Oblien sessions
  and daemon credentials use Keychain. A second device can recover the workspace's
  private `daemon.token` through its authorized runtime/SSH connection.
- **Backends:** cloud HTTP/runtime proxy and SSH use shared Swift service protocols.
  Workspace metadata uses the same authenticated daemon transport as chat operations.
- **Cloud controls:** workspace Overview keeps common actions together; Manage opens
  storage, workloads, desktop setup, network, public access and other infrastructure
  pages through the SDK. These controls depend on provider capabilities. See
  [Workspace controls](../../docs/apple/WorkspaceControls.md) for coverage and verification.

### Notification controls

- **Settings → Notifications** opens iOS notification settings for device-wide permission,
  sounds and delivery style, and lists the saved agents' notification preferences.
- **Agent Settings → Notifications** controls that profile's current and future chats.
  **Chat menu / long-press → Notifications** controls one chat. A muted agent takes precedence.
- **Visible chat:** the foreground notification delegate suppresses banner, sound and badge
  presentation only for the exact chat on an active screen. Navigation, tab changes and scene
  changes update view-owned visibility tokens. Other chats, including the same agent's, still alert.
- **Authority:** `notificationsMuted` lives on workspace agent/chat records. The daemon enforces it
  for all notification conditions and delivery channels, including when the app is closed. iOS
  updates the metadata cache only from acknowledged snapshots, and filters in-flight foreground
  pushes against that confirmed cache. Device registration and tap routing remain independent.
- **Compatibility:** changing a persistent mute requires `notificationPreferencesVersion: 1` in
  daemon health. Older services show an update requirement; there is no local-only mute fallback.
  Visible-chat suppression works with existing chat-targeted pushes without a daemon update.

### Liquid Glass conventions
Glass is the **navigation/control layer only** (tab bar, toolbars, FAB, selection,
terminal overlays). Content — cards and list rows — stays on solid elevation fills
(`Surface`/`SurfaceAlt`). Glass is never nested on glass; adjacent glass is grouped in a
`GlassEffectContainer`. The brand accent `#E25D3E` tints only primary actions.
