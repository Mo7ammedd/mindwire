# Git author settings

Source Control → repository menu → Commit Author opens the same native form used
when a commit needs a name and email. **Save Author only saves settings.** It keeps
the commit message, index and working files unchanged. Committing is a separate action.

| Scope | Applies to |
| --- | --- |
| This repository | Explicit native `user.name` and `user.email` in that repository. |
| This workspace | The default for this daemon's projects, including future projects. |
| All workspaces | The default distributed by this Mindwire app to every connected workspace, including future connections. |

Repository overrides take precedence over workspace overrides, then the shared
default. Use inherited author clears an override. Existing native Git settings
remain the fallback when no Mindwire default applies. Attribution is never inferred
from a GitHub login, Oblien account or agent subscription.

## Authority and delivery

The app stores the user's shared-default preference and pending delivery receipts.
It does not pretend this local preference is already installed on an offline
workspace. Each daemon owns its applied settings, exposed by
`GET /workspace/git/identity`. `PUT` on the same route saves a scope, without entering
the commit operation dispatcher. Both require `healthz.gitIdentityVersion >= 1`.

Shared-default writes include a stable `requestId` and the previously observed
`expectedRevision`. Lost acknowledgements retry the same intent. A newer remote
default produces a conflict instead of being overwritten by an old delivery.
Acknowledgements are scoped to the daemon registry identity, so replacing a
workspace requires applying the preference again. Successful workspaces are skipped
on routine reconciliation. Stopped/offline/old-service workspaces stay pending;
author synchronization does not start machines or install services.

The queue is owned by `Stores`, persists across app restarts, and runs from the
foreground app lifecycle. Closing the author form does not cancel delivery. It is
an app preference applied across connections, not an account-profile synchronization
service between different phones.

## Native Git integration

The daemon stores shared and workspace defaults in private native Git config files.
A conditional-only include in the Git user's global config points to workspace
project bindings. Conditions match registered project paths and linked-worktree Git
directories; unrelated repositories and the user's existing global name/email are
preserved. New repositories initialized later inside a project inherit the default
without requiring the app to stay open. Explicit repository config wins through
Git's normal precedence. Project removal removes its binding.

Name/email pairs are written atomically under Git's config-file lock. Native Git
commands from the app, agent harnesses and terminal resolve the same values.

## Verification

- Daemon `internal/gitauthor` and `internal/api` tests cover scope precedence,
  no implicit commit, locked configuration, request replay, stale clients, future
  repositories, unusual paths and separate workspaces.
- iOS `GitAuthorDefaultsTests` cover offline delivery, restart recovery, request
  coalescing and superseded preferences. `GitReviewTests` exercise independent
  author setup, preserved drafts/staged files and native screen rendering.
