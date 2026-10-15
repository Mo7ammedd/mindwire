# GitHub accounts and workspace Git

GitHub connections are independent of the workspace provider. Personal tokens talk
directly from iOS to GitHub for identity and repository browsing; they do not need
an Oblien login. The Oblien GitHub App remains a separate connection method.

The phone stores personal tokens and SSH keys in Keychain. Project and workspace
records contain only a connection ID, GitHub identity, method, and access lifetime.
The same account can browse repositories on the phone and authorize Git on a
selected server.

## Where actions run

| Action | Responsibility |
| --- | --- |
| Connect an account, browse, choose a repository | iOS and the selected GitHub adapter |
| Clone into a workspace | iOS submits the existing project operation; the daemon runs Git in that workspace |
| Status, diff, file contents | iOS reads the server checkout through workspace exec, without optional Git index locks |
| Stage, unstage, discard, commit | iOS submits a durable daemon operation in the server checkout |
| Fetch, pull, push | The same daemon operation service uses the selected GitHub connection |
| Agent Git commands | The agent receives a Git helper for the project's selected connection |

Cloning was already a daemon project operation. This feature adds account
selection and reusable authentication. With `gitOperationsVersion >= 1`, all
app-managed writes for registered projects share repository coordination with
agent and project operations. Read-only browsing stays in the iOS Git service.
Older daemons and unregistered workspace directories retain the workspace-exec
compatibility path for local mutations. Native terminal commands use Git's own
locking.

Commits use the server's configured Git name/email. Missing identity produces
Git's configuration error; the app never invents an author or changes that
identity. Discard restores tracked files from the index and uses Git clean only
for selected untracked files, preserving ignored files. A failed restore never
falls back to deleting a tracked file. Pull only fast-forwards and push never
forces.

## Operation recovery

The phone saves a non-secret request ID before submitting a write. The daemon
records the operation before execution and keeps its result. Reusing the same
ID and intent returns that operation instead of running it again. Opening Source
Control or returning to the app observes pending work, including work started
from another device. **Retry pending operation** reuses the original ID if its
acknowledgement was lost; opening the screen alone never resubmits it.

Disconnecting or closing Source Control detaches the observer. **Cancel** requests
cancellation on the server. Operations have a 15-minute limit. After daemon
restart, unfinished operations are marked interrupted and never replayed
automatically. Cancellation/interruption can occur after some effects completed;
refresh the repository before starting another write.

## Choosing access

Add a connection in **Settings → GitHub → Add connection**. Personal access tokens
and SSH keys each have a native form with a required connection name. This label
is separate from the GitHub profile name; legacy records keep their current names
until edited. Select any connection to view its details, reveal/copy the local
credential, edit it, test it, or remove it with confirmation. Workspace/project
GitHub access and the repository picker offer **Manage connection** for the same
screen.

A personal token is checked against GitHub before it is saved. Fine-grained tokens should include the
repositories you need, with **Contents: read** for cloning/fetching or
**Contents: read and write** for pushing. GitHub may require additional permissions
for particular changes, such as workflow files.

**Create token on GitHub** offers fine-grained and classic creation links with
the chosen connection name. Fine-grained links preselect `contents=write`; classic
links preselect `repo`. The info sheet can also include `workflows=write` or the
classic `workflow` scope for Actions edits. Repository browsing derives owners
from visible repositories and does not require `read:org`.

SSH setup generates an Ed25519 key or imports an unencrypted OpenSSH Ed25519
private key. Copy the public key and follow **Add key on GitHub**, choosing
Authentication Key, then return to test and save. Older imported key formats are
preserved; native iPhone checks require Ed25519.

**Test connection** is explicit and bounded. Tokens check `/user` and a one-item
repository listing; success does not assert push access to every repository.
Classic scopes and token expiry are displayed when GitHub supplies them. SSH
checks authenticate natively at `ssh.github.com:443`, pinning GitHub's host keys
from its HTTPS `/meta` endpoint; they do not execute a command or clone a repo.
The connection list shows the result of the last check, not ongoing health.

Use **GitHub access** on a workspace to set its default, or on a project to choose
an override. New clones remember the connection used in the repository picker.
Projects without an override inherit the workspace default. Other Git hosts keep
their native server authentication. **Use server's Git credentials** explicitly
retains an existing server setup. A GitHub CLI connection uses that workspace's
current `gh` login.

- **For each operation or agent run** is the default. iOS supplies a credential
  when work starts. The daemon gives Git a repository-scoped helper and discards
  its grant on completion or cancellation. Clones and agent runs continue after
  the phone disconnects; they do not call back to the phone for each Git command.
  Git writes also continue after disconnecting. A later run, including a reply
  that resumes a completed run, needs fresh access.
- **Keep on this workspace** explicitly saves the credential on that server for
  future runs and terminal Git. The app can then reconnect from another device
  without the original phone being online. Workspace settings list saved
  connections so they can be selected or removed there.

Temporary access does not turn a PAT into a short-lived GitHub token or reduce
its actual permissions. The selected server is trusted with the credential. Use
a token limited to the repositories that server needs.

The current Oblien endpoint issues expiring, read-only installation tokens. Those
tokens can clone/fetch/pull, but cannot be saved for future runs or used to push.
Use a PAT with write access, an SSH key, or server credentials for pushing.

## Recovery and compatibility

Editing validates changed credentials before replacing the Keychain value.
Failed validation and cancellation preserve the previous name and secret.
Renaming works offline; a token replacement must belong to the same GitHub
account. Add a different account as a new connection. Repeated taps cannot create
duplicate records, and a successful test can be reused for an immediate save.

Replacing a token or SSH key keeps its connection ID and project
selections. Save the connection again in workspace GitHub settings to refresh an
explicitly saved server copy. Removing a connection from the phone removes only
the local secret. **Remove saved access from this workspace** removes the server
copy and invalidates its temporary grants. Revoking a token at GitHub is separate.

A missing connection produces a reconnect error; another account is never chosen
as a fallback. SSH keys require SSH remotes, and PATs require HTTPS remotes. Git
origin URLs stay credential-free.

GitHub access is advertised by `healthz.gitAccessVersion >= 1`; durable writes
add `healthz.gitOperationsVersion >= 1`. An older
daemon retains the existing clone flow; authenticated agent Git, saved access,
and fetch/pull/push require the matching daemon build. This change does not deploy
that build to a server automatically. On older daemons, a network request may lose
its result; refresh repository status before retrying there. New daemons return
the saved operation outcome.

Named credential management and native connection tests are iOS changes; they
do not require a new daemon protocol or release.

## Pull requests

On a feature branch, Source Control offers **Create Pull Request**
under the branch row and in **Sync Repository**. The sheet shows the repository,
source/base branches, and a committed comparison with file, line, and commit counts. Edit the title and
description, select a base branch, and optionally create a draft. **Push & Create
Pull Request** publishes through the existing durable Git operation before
creating the PR through GitHub's API. An already published branch skips the push.
Creation and the resulting PR number stay inside Mindwire; **View on GitHub** is
an optional link after creation.

Opening the form reads the current branch tips from GitHub. The preview compares
the local committed HEAD against the merge base with the selected remote base,
using immutable Git object IDs. Local staged and working files appear separately
under **Not committed**, with **Review and commit** opening the existing Commit
sheet. Committing refreshes the PR preview; it does not publish automatically.
The comparison file list reuses the existing Git rows and diff viewer in read-only
mode. Changing the selected base cancels the old preview request. If its remote
commit is not present locally, **Fetch latest branches** uses the existing durable
Fetch action before retrying the comparison.

Push readiness comes from GitHub's current source tip rather than a potentially
stale local tracking ref. Creation rechecks the confirmed local HEAD, and the
GitHub client checks both the published source and the reviewed base tip before
posting. A changed base requires a refreshed comparison. Incomplete previews and
branches with no commits against the selected base cannot be submitted.

The project’s existing Git binding selects authentication. Native or GitHub CLI
access runs `gh api` on the workspace without exporting its credentials. A selected
personal access token is read from this phone’s Keychain for each API request.
SSH keys and clone-only Oblien App access cannot create PRs through GitHub’s API;
the sheet links to the existing GitHub Access screen to select a token or signed-in
CLI. Fine-grained tokens need Contents and Pull requests read/write permissions;
the token creation link preselects both. Classic tokens use `repo`.

Only committed work is published; staged and unstaged files stay in the workspace.
Reopening the sheet never pushes automatically. Repeated taps share the existing
operation guard, and an interrupted push must recover its receipt before the PR
is created. A changed branch, HEAD, or remote requires reviewing the new details.
Existing open PRs are shown instead of creating duplicates. A failed creation
response is reconciled with a read before reporting failure; the POST is never
automatically repeated.

Availability uses local origin refs, cached until the branch/HEAD changes or an
explicit refresh or remote operation occurs. No polling or network fetch runs just
to display the action. Opening the form loads the base branches and default from
GitHub using the selected account. The action stays hidden for
detached/unborn branches and known default branches. A new feature branch can open
the form to review and commit its local files. It supports GitHub HTTPS/SSH origins whose fetch and single push URL name
the same repository. Other hosts and ambiguous push destinations keep their
existing Git controls. This is an iOS change and reuses the current daemon protocol.

## File operation feedback

Stage, unstage, and discard show progress in the affected file’s existing icon
slot, without inserting a progress section or changing the row’s dimensions.
The file moves only after the operation completes and repository status is read.
Unrelated cached diff excerpts remain loaded; explicit refresh still revalidates
all excerpts. Durable operation streams deliver completion immediately, with a
receipt read and polling fallback if the stream disconnects. Reopening the screen
recovers pending work without redisplaying old failed operations.

The daemon allows staging and unstaging while an agent, command, or terminal is
active. It retains Git job serialization, project synchronization/removal guards,
and Git’s native index lock. Other mutations retain their active-work guard, with
an actionable conflict message. This admission fix requires updating the daemon
service; the app does not bypass coordination on older services.

## Verification

`GitHubCredentialTests`, `GitHubAccessTests`, and `SSHTransportTests` cover
credential validation, Keychain edits/removal, stable project bindings, repeated
actions, cancellation, native SSH authentication, and the credential screens.
Run simulator tests with `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` so the
test app receives the entitlements needed for Keychain access.

The opt-in `testLiveGitHubSSHRejectsAnUnregisteredKey` uses a new fixture key to
check GitHub's live metadata, host-key validation, and SSH rejection response.
Set `MINDWIRE_LIVE_GITHUB=1` in the test target's environment to enable it. It
does not register a key or modify a GitHub account.
