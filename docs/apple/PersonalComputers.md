# Personal computers as workspaces

Mindwire connects a phone to the same workspace API used by cloud and SSH hosts.
Projects, agents, chat history, approvals, Git operations and author settings remain
owned by the computer's daemon. The app stores connection credentials and caches.

## Connections

- The normal `mindwire connect` flow creates internet access through Cloudflare,
  privately acquiring its verified helper when absent. Same Wi-Fi is optional.
- Direct SSH over a reachable LAN, public address or existing VPN needs no relay.
  Select `--relay none` to use that path alone.
- Internet relays carry an SSH byte stream inside a WebSocket. SSH authenticates
  both devices and encrypts the content even when a provider terminates HTTPS.
- Relay configuration is independent of workspace identity. The CLI provides
  Cloudflare, ngrok and custom WSS adapters. A configured Oblien tunnel can use
  that custom adapter; automatic Oblien tunnel provisioning is not part of this
  change. No cloud workspace is required. Direct and relay addresses can coexist.
- A temporary relay hostname cannot promise reachability after that relay restarts;
  a stable configured hostname or a VPN is appropriate for unattended access.

## Pairing

The computer creates an expiring pairing invitation containing its identity,
SSH fingerprint, connection addresses and a random one-use capability. The mobile
client generates its own key, verifies the fingerprint before sending credentials,
and requests approval. A pairing connection can only access the pairing handler;
it cannot execute commands or reach the workspace API. The computer approves the
specific public key. Retrying the same request is idempotent.

`mindwire connect` now uses one connection flow rather than asking the user to choose
between resuming, refreshing an address, and pairing. The app retains a per-computer key
before the first network request. A signed request proves possession of an existing key
to a daemon advertising `pairingVersion: 2`, so a saved phone reconnects without another
approval. A missing key takes the same QR through explicit computer-side approval; the
owner can replace the listed old approvals atomically instead of accumulating duplicates.
The app never changes a saved computer's pinned identity based on a new QR.

Approval and completion are separate. The terminal waits for the phone's receipt after
its connection and workspace are saved. Legacy address-only reconnect codes still require
a saved key; the app directs a missing-key phone to a fresh `mindwire connect` code.

The unified flow was verified with the real CLI and daemon over native iOS SSH in
WebSocket: a retained key without mobile metadata, repeated scans, offline local
removal followed by explicit key replacement, and a saved-address reconnect without
scanning. The final registry contained one approved phone and the same daemon PID.
These protocol/CLI changes require a new daemon and npm release.

Each approved device has an independent key. Revocation closes that device's active
connections as well as rejecting future connections. Pairing secrets and private
keys never enter workspace snapshots, application logs or QR links after pairing.

Daemons advertising `pairingVersion: 3` require the existing Ed25519 proof on every
pairing POST, including acknowledgement retries. GET status never returns a daemon
credential, and owner-facing status omits reusable request proofs. Revoke/replace
also invalidate pairing acknowledgements and close pairing connections; an invitation's
expiry closes already-authenticated pairing sessions. The app already signs these POSTs.

Computer keys, daemon tokens and pending pairing receipts use
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. All existing copies, including
unread pending receipts, migrate in place on first Keychain use. This preserves
reconnect while preventing new backups from cloning one phone's approval onto
another device. Direct computer access runs with
the owner's account permissions; selecting an initial project directory is not a sandbox.

## Execution and terminals

The daemon provides native filesystem, resource and argv-based execution APIs.
These implement the existing mobile `WorkspaceService` interface instead of adding
a separate computer UI. Git keeps its existing service and daemon operation paths.

Persistent terminals belong to the daemon, with stable session identifiers,
bounded replay, resize and explicit close. Detaching a mobile view leaves the
process running. Unix PTYs and Windows ConPTY implement the same terminal contract.
The existing SwiftTerm view and terminal tabs consume that contract.

## Mobile setup and management

Workspace creation presents Oblien Cloud, Your computer, and SSH server as separate
native cards, followed by saved computers and servers. Opening a specific connection form keeps that type fixed. The generic
Add connection form in Settings retains its Computer/SSH server selector.

Settings → Computers & Servers lists both connection types. Details share workspace
rows and terminal views, expose private port forwarding, and provide rename, removal,
manual connection checks and SSH credential editing. Editing preserves the connection
ID and linked workspaces; replacing a credential changes its Keychain reference so
cached transports cannot reuse the old secret. Re-pairing requires the same computer
identity and updates its existing connection rather than duplicating it.

The computer form shows both install commands and the native QR scanner. Setup help
explains SSH encryption through Cloudflare, automatic startup, and temporary tunnel
address changes. First pairing asks whether to enable a per-user startup guardian and remembers the choice;
`mindwire startup status|enable|disable` manages it. An explicit Stop stays stopped
until Start/Connect. The CLI reports when a native startup service is unavailable.
Launch and startup registration share a lock queue, including stale-lock recovery.
Controller, guardian and lock records carry process birth to reject reused PIDs.

Connect and Reconnect verify an actual WebSocket connection and the Mindwire SSH
banner before presenting a QR. A running relay process alone is not readiness.
The controller checks the path periodically and an explicit connection requests a
fresh check. Concurrent starts join the same controller and check. Older background
controllers are replaced under the launch lock while the new controller adopts
their daemon and relay, preserving open terminals and phone identities.

Temporary internet loss retries the existing address. Failed relays are replaced
only after a recovery grace period and a successful provider reachability check.
The grace period allows Cloudflare's initial 60-second negative DNS cache to expire;
reallocating a hostname earlier can repeat that failure indefinitely. Relay repair
never restarts the workspace daemon. A new temporary hostname still needs a scan
if the phone has no other reachable saved route.

One shared iOS path monitor invalidates stale connections on network handoff or
foregrounding. Offline attempts wait for connectivity, concurrent requests share
the same opening attempt, and no mutation is replayed by route selection. The
existing terminal cursors/input receipts preserve the same shell. Private forwards
retain their local port. Verified `/computer` reads refresh the existing saved
connection's routes, without creating another workspace or storing credentials.

`mindwire connect` reports an authenticated saved connection or presents the same
pairing QR used by `mindwire reconnect`. `mindwire connect resume` is a legacy alias
for the automatic flow; `mindwire connect pair` always requests a QR. A permanent
tunnel hostname or VPN provides address stability across restarts without a scan.
First-time scripts use `--startup` to opt into startup; noninteractive connect
otherwise leaves that preference unchanged.

An offline computer can be recovered from its workspace's **Reconnect Computer** action,
the workspace list context menu, or connection settings. Recovery first verifies the saved
addresses. If a temporary tunnel address changed, run `mindwire reconnect` on the computer
and choose **Scan Connection Code** in that sheet. This updates the same workspace with its
existing keys. Concurrent retries share one attempt; reconnect does not repeat the initial
startup question. Existing transports retry dropped connections and react to network changes;
there is no hosted address directory or additional provider dependency.

The native route race preserves host-identity, rejected-key, rejected-code and
internet-tunnel failures instead of reporting every failure as an unreachable
computer. Only network failures retry. These retries finish the SSH handshake
before any workspace operation is sent, so they cannot repeat commands or messages.

**Remove from This iPhone** removes the saved connection, credentials, and cached workspace
data locally, even when offline. It does not delete computer files, native chats, or running
programs. Removed connections are not restored by delayed metadata reads or reconnect attempts.

Send carries a durable `requestId` on daemons advertising `turnRequestVersion: 1`.
Automatic retries and restored-draft retries reuse it. The daemon atomically stores
ingress/run/receipt before execution and returns the accepted run on replay, including
after completion. Older daemons do not receive automatic ambiguous Send retries.

Private ports use the existing native SSH forwarder. Paired computers first acquire
an expiring, per-device grant from `/computer/forwards`; the app renews it while active.
Close and revocation close its live channels. Listeners bind only to this iPhone's
loopback interface. A WKWebView opens HTTP previews through that same connection.
The app saves only connection IDs and remote/local port numbers. Returning to the
foreground or relaunching restores these listeners and renews their existing grant
identities. Network changes restart only the forward's listener; shared computer,
daemon and chat connections retain their existing recovery behavior. The preview
reloads on a new listener, including when its local URL stays the same. Close removes
the saved forward, and deleted connections are never restored.
The previous local address is reused when available; if another listener occupies
it, a new loopback port is allocated, saved and reflected in the preview.
This is separate from Oblien's public-access API and from future desktop sharing.
Computer port forwarding requires the daemon changes after 0.1.24; an older daemon
shows an update message. Plain SSH servers use their existing forwarding support.

Computer service updates use the CLI controller's durable `/computer/update` request.
The app submits before waiting, so leaving the app cannot lose the update. The controller
downloads the published release, verifies it and restarts with the same pairing identity
and ports. Automatic updates wait for idle; manual Update and Update All authorize an
immediate restart after download, closing Mindwire terminals and potentially interrupting
active agent work. The update sheet shows a short restart notice. Manual intent promotes
the same queued request and preserves its download; it never overrides another updater's
exclusive lease. The daemon cancels its active turns and saves their partial output before
exit, bounded by its shutdown deadline.

Mindwire terminals are PTYs created by the app, including detached shells. They are separate
from the paired SSH control connection and from Terminal.app on the computer. The terminal
manager's Close terminal action terminates the selected session after native confirmation.
For older published services without forced restart support, a manual update can close these
PTYs after download; other active work needs to stop once before upgrading to the new protocol.

Recheck quietly observes the same remote request, without repeating installation or replacing
a ready agent page with preparation UI. Only a real service change shows install progress.
Queued, failed and completed results remain visible in the shared update sheet instead of
disappearing when an Update All batch returns. Completion also verifies the running version.

Manual restart checks passed with a real CLI controller and an open PTY, including exclusive
leases and rollback. The iOS integration test also upgraded a disposable published 0.1.25
service to 0.1.26 over paired SSH in WebSocket: automatic waiting, explicit terminal closure,
reconnection, and retention of the pairing and update request all passed. The force protocol
itself requires the next daemon release; no development binary was installed on a user's computer.

The connection-management change passed the iOS simulator build and 47 connection,
SSH, agent-readiness and workspace checks, including live direct-SSH and WebSocket pairing, files, command streaming,
private HTTP preview, grant cleanup and recovery of the same daemon PTY. Nine SDK/CLI
checks passed, including concurrent start, idle-safe shutdown and update rollback.
The daemon's computer, workspace execution and API race suites passed. This change
has not been published as a packages/daemon/npm release or tested on a physical phone.

## Delivery checklist

- [x] Daemon connection, pairing and revocation, direct SSH and WebSocket bridge.
- [x] Native workspace execution/files/resources and persistent terminal API.
- [x] npm CLI, verified release installation, background lifecycle and relay adapters.
- [x] iOS pairing, pinned transport, existing workspace and terminal integration.
- [x] SDK contracts, protocol docs and security/reconnect tests.
- [x] macOS CLI lifecycle and rollback checks; iOS simulator direct SSH and real
      Cloudflare WSS checks, including files, project metadata, exec streaming and
      recovery of the same PTY.
- [x] Signed iPhone build and installation; live Cloudflare WSS, workspace and
      terminal recovery passed on Abdelhamed's iPhone.
- [x] Internet-default startup with no preinstalled helper, verified download,
      concurrent-start reuse, and readiness after the relay connection opens.
- [x] 119 iOS workspace regression checks and seven physical-iPhone connection,
      SSH and protocol checks. The live iPhone test used only the public WSS route,
      including after a service restart; local SSH could not satisfy that test.
- [ ] Direct LAN from the physical iPhone: the advertised Mac address was
      unreachable in the device test. Simulator direct SSH passed.
- [x] Coordinated packages/daemon/npm v0.1.23 release, including the Linux CLI lifecycle
      and terminal-recovery checks in the successful release gate.
- [ ] Native Windows runtime verification. Cross-compilation passed.
- [x] Publish the npm command-entry fix as v0.1.24 and verify the installed public package.
- [ ] Ship the updated iOS app.

## Development checks

The public setup guide is in the daemon repository at
`apps/web/content/docs/guides/personal-computers.mdx`.

The full daemon race suite and Go vet passed. The SDK typecheck/build and full
117-test suite passed; the subsequent relay readiness fix passed its focused
provider/helper tests. The documentation build and MDX/type checks passed.

On 2026-09-25, checking the published npm command found that v0.1.23 exited silently
through npm's executable symlink on macOS/Linux. The SDK source now resolves the
entry path before dispatching the CLI, and regression tests cover linked commands,
direct execution, and importing the module. The packaged-install release gate also
requires the installed command to display setup help. The v0.1.24 release passed all
release gates and published the daemon, container images, and npm package. A temporary
global install of the public npm package started the matching v0.1.24 daemon,
displayed its QR and expiring invitation, and stopped cleanly. The camera scanner
was inspected but not exercised on a physical phone in this check.

The SDK's `test/computer-live.test.ts` uses a disposable state directory and a
development daemon selected by `MINDWIRE_COMPUTER_TEST_BINARY`. It checks duplicate
start prevention, native file/exec operations, terminal input receipts and replay,
idle admission, retained identity and update rollback. It never installs a test
binary onto an Oblien workspace.

The unreleased recovery changes passed the focused daemon race suites, SDK build,
and startup/recovery tests. A real macOS launchd check verified four concurrent
startup requests against abandoned locks, a live guardian, controller recovery
without replacing the daemon, durable Stop and registration removal. Linux and
Windows startup command generation was tested; native startup on those systems
remains unverified. The iOS simulator passed 32 connection/chat/network/SSH checks;
the final seven live transport checks also verified that an unreachable LAN route
does not delay the working WebSocket route. Network changes were injected while
using real SSH/WebSocket sockets, persistent PTYs and private HTTP previews.
Disposable services and pairing invitations were removed after these checks.

For native mobile integration, start a disposable computer service, then run
`packages/sdk/scripts/computer-ios-fixture.mjs STATE_DIRECTORY PRIVATE_FIXTURE_FILE`.
The script creates five-minute direct/WS invitations and approves only the named
integration-test device. Set `MINDWIRE_COMPUTER_FIXTURE` in the XCTest environment
to that private file. On a physical phone, copy it into the app's Documents
container and set the environment variable to its filename. Remove these fixtures
and stop the disposable service after testing. Pairing secrets must not enter logs.

Android is a future client of the same wire protocol; this checkout contains an
iOS client and a web client, not an Android app. Personal-computer desktop capture
is a separate capability from terminal access.
