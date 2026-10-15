# Mindwire monorepo migration

The canonical repository is `oblien/mindwire`. The former `pocket-agent` working tree has been
imported, including its uncommitted app fixes, and the old checkout has been removed after
verification. Continue development in the `mindwire` checkout.

The complete original checkout, including Git metadata, uncommitted changes, and ignored files,
is backed up locally at `.git/legacy/pocket-agent/checkout-20261015.tar.gz`. Every archived file
was checked against the original using SHA-256 before removal. The same directory contains a
verified Git bundle, working-tree patch, source-to-destination manifest, and recovery instructions.
This recovery backup is local Git metadata; it is not included in commits, clones, or pushes.

## Paths

| Before | After |
| --- | --- |
| `pocket-agent/apps/ios` | `mindwire/apps/apple` |
| `pocket-agent/apps/web` | `mindwire/apps/protocol-lab` |
| `pocket-agent/docs` | `mindwire/docs/apple` |
| `pocket-agent/artifacts`, `marketing` | `mindwire/apps/apple/artifacts`, `marketing` |
| `pocket-agent/icon-themes` | `mindwire/apps/apple/icon-themes` |
| `pocket-agent/scripts/app-store`, `scripts/icons` | Same paths in the monorepo |
| `mindwire/daemon` | `mindwire/packages/daemon` |
| `mindwire/packages/docker` | `mindwire/deploy/docker` |

The source app import is based on `oblien/pocket-agent` commit
`c1cf1cba61ed56faa85ad1042c34ef9537429c1b`, plus the working-tree changes present on October 15, 2026.
The runtime base is `aa26e91f0dba38d6942415cfeaedd2e296eb060b`.
The original repositories' prior commits have not been rewritten or squashed.

`apps/web` remains the product/documentation website. `apps/console` remains the full browser app;
`apps/protocol-lab` is a developer diagnostic client, not a second product console.

## Go module

The Go module now matches its source location:

```text
github.com/oblien/mindwire/packages/daemon
```

Update imports from `github.com/oblien/mindwire/daemon/...` to
`github.com/oblien/mindwire/packages/daemon/...`. The native SDK is under `/sdk`.
Existing released tags retain their old source layout. New releases publish a matching
`packages/daemon/vX.Y.Z` module tag in addition to the existing `vX.Y.Z` product release.

## Stable distribution identifiers

The npm package remains `mindwire`; its CLI remains `mindwire`, and the executable remains
`mindwired`. GitHub releases still use the existing repository and `vX.Y.Z` asset URLs. The
`ghcr.io/oblien/mindwire-runtime` and `mindwire-console` image names are unchanged. Do not rename
these identifiers as part of a folder move: installed clients already use them.

## Apple platforms

The directory is platform-neutral; the current XcodeGen target still builds iOS/iPadOS.
A native macOS app requires platform implementations for the transcript, editor, terminal wrapper,
lifecycle, notifications, clipboard, and desktop controls. visionOS needs its own compatibility pass.
Share models, services, harness integration, and portable SwiftUI components within `apps/apple`;
keep operating-system implementations at their existing feature boundaries when adding targets.

Folder consolidation does not make iOS-only dependencies work on another Apple platform.

## Local development

`bun dev` starts the daemon and console from this checkout. `./dev.sh` delegates to the same
launcher. The Apple app no longer requires a sibling runtime checkout for local development.
Regenerate Xcode projects with `bun run apple:generate`. Generated projects, dependencies, build
output, local credentials, and untracked captures are not imported.

The former iOS test browser runs as `bun run dev:protocol` on port 5175. The full console keeps
5174. Use one root `bun.lock`; the diagnostic client's old npm lockfile is superseded by it.

## Licenses

The runtime, SDKs, console, and website remain Apache-2.0. Original material in `apps/apple` uses
the source-available Apple client license: inspection and private personal builds are permitted;
redistribution and publishing derivative apps require written permission. The diagnostic client,
Apple notes, and Apple tooling outside that directory remain AGPL-3.0. Third-party terms and
valid earlier license grants are unaffected. See [component licenses](../LICENSING.md).

## Migration verification — October 15, 2026

- Every tracked or untracked, non-ignored file in the original checkout was accounted for.
  Root metadata was merged into the monorepo equivalents; the old npm lockfile was replaced by
  the root Bun lockfile. The full recovery archive also retains both and all ignored files.
- Frozen dependency installation, TypeScript checks, SDK and console tests, native runtime
  integration tests, Go race tests, and `go vet` passed. The SDK, website, console, diagnostic
  client, and native daemon build passed. Website desktop/mobile browser checks passed.
- The iOS simulator build passed. Of 150 selected Apple tests, 148 passed, including every
  selected chat, draft, lifecycle, native-chat, and port-forward test. Two source-control UI tests
  failed and failed again in isolation: `testPullRequestAppearsAfterCommitAndUsesTheCompactNativeSheet`
  and `testRepositoryMenuStaysVisibleAcrossStatusRefreshes`. Their tests and source-control
  implementation are byte-identical to the original working tree. These failures remain unresolved.
- Docker Compose configurations and build input paths were validated. Docker images were not
  built because no Docker daemon was available locally.

These checks record local migration validation, separately from GitHub CI and release publication.
