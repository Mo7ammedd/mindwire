# Harness compatibility in the app

The workspace's daemon owns the supported Codex, Claude, Grok and OpenCode versions. The app never
installs npm latest or compares a CLI version against a hardcoded list.

`harnessPolicyVersion: 1` advertises support in health/catalog. `GET /agent` includes `software`, and
`GET /agent/software` returns the same decision with a catalog check. The daemon's `recommendedVersion`
is the update target; `latestVersion` may require a newer service. `updateAvailable` and
`requiresDaemonUpdate` can both be true. Render each separately.

The Software section displays compatibility, an exact update target when available, a service
upgrade requirement when needed, and Check for updates. Agent rows reuse the shared packages/daemon/harness
work state. Known incompatible versions block new turns while history, running chats and settings remain accessible.
An untested existing CLI remains usable and is labeled in Software settings.

Checks are shared by workspace and harness, not by persona. Navigation uses a five-minute client
cache; manual refresh bypasses it. A late check cannot undo an installation, and read failures keep
the last daemon decision. Metadata refresh never starts an installation.

Service updates are automatic by default while the app is active, with an opt-out in Settings.
Foreground reconciliation schedules one update per reachable, installed workspace; busy workspaces
retry after 15 seconds, and failed attempts back off for five minutes. The Update service action
uses the update path even when it joins a first-run preparation. Recovery still launches the
installed binary, and only a confirmed missing executable permits a first install.

Services advertising `serviceUpdateVersion: 1` grant an idle lease after the release binary has
downloaded. It blocks new mutations/turns across all clients during replacement, and refuses while
chats, terminal transcript writes, CLI setups, native logins, project/Git jobs, or desktop sessions
are active. A failed installer releases the lease; it also expires after one minute. Older services
need one explicit upgrade with the legacy activity checks before automatic updates become eligible.
The app downloads published GitHub release assets and verifies the running version after launch.

The daemon also reports `software.missingDependencies`. An installed CLI is not proof that its
shared prerequisites exist. On explicit agent preparation, missing tools run through the normal
setup job and its live progress. An active chat defers repair so history and Stop remain accessible;
a failed repair requires Retry. Codex declares Bubblewrap on Linux; macOS uses native Seatbelt.

Old services may continue running their existing CLI. Fresh installs and updates require the new
policy capability, because the old endpoints install unrestricted latest versions. Unknown future
policy versions also leave install/update controls disabled. Both use a clear service-update message.

The daemon stores and validates the compatibility catalog and selected executable. The app caches
display state only. Catalog publishing and version verification live in the daemon repository's
`packages/daemon/HARNESSES.md`; no new app build is needed to approve a new CLI/daemon combination.
