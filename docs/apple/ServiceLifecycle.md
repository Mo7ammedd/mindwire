# Workspace service lifecycle

Mindwire's workspace service is supervised independently of the mobile app. Its binary,
credential and workspace data remain in the account's `~/.mindwire` directory.

| Workspace | Process manager |
| --- | --- |
| Oblien | One `mindwire-service` workload, enabled, with `restart_policy=always` |
| SSH server with systemd | One service per SSH account, enabled at boot; runs as that account |
| SSH macOS host | launchd, using a system daemon when permitted, otherwise a login agent |
| New Docker sandbox | Docker `unless-stopped` plus the shared service guardian in the container |
| Paired computer | The existing Mindwire computer guardian and startup setting |
| Host without an accessible native manager | A singleton background guardian; app recovery after reboot |

The mobile installer registers startup during installation and recovery. Previously installed,
healthy services are registered once when used, without terminating their work. Success is
cached across app launches; failed optional registration is retried after a cooldown. Workload
registration uses a deterministic workspace-scoped ID, verifies the command before modifying
it, and tolerates a competing phone or a lost create response. It never modifies other workloads.

The supervisor runs `service-runner.sh` in the foreground. The runner reads `daemon.token`
from the workspace, so neither the workload command nor its environment contains the token.
It preserves the installation account, home directory, tool PATH and existing state. A legacy
detached process is allowed to finish; supervision takes ownership when it next exits. A macOS
login agent starts at login; boot without login requires permission to install a LaunchDaemon.
A Linux user service requires lingering. Unsupported hosts are not advertised as boot-managed.

## Atomic updates

- `daemon-install.lock` serializes the complete installation and verification across clients.
- `daemon-activation.lock` prevents supervisor restarts while the old process is stopped and
  the staged binary is atomically moved into place.
- `daemon-run.lock` is held by the running service, preventing multiple supervisors from
  launching duplicate daemons. The optional background guardian also has its own singleton lock.

The update lease still protects active work. Automatic updates refuse busy services; explicit
updates retain their existing force behavior. The supervisor can start the replacement after
the activation gate opens, while the installer continues to hold the transaction lock through
the health check. Locks are released by the OS on exit, including failure/cancellation.

## App recovery

Project/source-control preparation can start an installed service after a refused connection,
even when first installation is disabled. It first verifies that the workspace is running and
uses the shared workspace job. It does not wake a stopped workspace, replace the binary, or
install an absent service. Sign-in failures, request cancellation and a phone with no network
do not trigger this path. Failed automatic recovery has a cooldown; explicit refresh bypasses it.

## Verification

`DaemonStartupTests`, `DaemonServicePreparationTests` and `WorkspaceDaemonTests` cover workload
ownership, conflicting creates, policy repair, cached migration, recovery and update intent.

For real process and lock checks, run `DaemonStartupTests/testEmitScriptsForHostLifecycleChecks`
on the simulator with `TEST_RUNNER_MINDWIRE_STARTUP_SCRIPTS` set to a new temporary directory,
then run `python3 apps/apple/scripts/check-daemon-startup.py <that-directory>`. This executes the
production scripts against a disposable daemon fixture. It checks legacy adoption, concurrent
starts, crash recovery, activation locking, busy updates, state preservation and relaunch. Its
launchd check uses a fake command and never registers a service on the developer's Mac.
