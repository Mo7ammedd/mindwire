# Background turns and iPhone lifecycle validation

Validated on 2026-10-06 using a physical iPhone 12 running iOS 26.5.2.
The UI screenshots contain fixture projects and conversations.

Mindwire's supervisor imposed a hidden 30-minute limit on normal turns. Two
failures recorded on the connected Mac occurred at that limit. Normal turns
now run without a default deadline and remain independent of connected viewers.
An explicitly configured `TURN_TIMEOUT` still applies, and user Stop remains
available. A stopped process, a configured deadline, and user cancellation now
produce distinct outcomes without discarding the native conversation.

The iOS changes allow workspace browsing above `/root` to `/`, use the outline
Projects menu icon, and retain the visible conversation during temporary inactive
states such as Notification Center. Actual backgrounding detaches the viewer;
it does not send Stop to the agent.

Validation:

- All release jobs passed for [v0.1.45](https://github.com/oblien/mindwire/actions/runs/37460116131).
  The backend changes are merged in [PR #33](https://github.com/oblien/mindwire/pull/33).
- The Go regressions cover more than 24 days of **virtual** elapsed time, closing
  and reconnecting a real HTTP viewer, explicit deadlines, real process-group
  termination, and continued access to the same saved native session.
- 55 app, chat activity, and chat lifecycle unit tests passed on the iPhone.
  The new lifecycle test verifies that live fixture messages and the transcript
  survive inactivity, backgrounding detaches without cancellation, and returning
  performs one catch-up and reconnect.
- Physical UI tests passed for Notification Center with an expanded tool and
  composer draft, navigation from the server's home to filesystem root, and the
  Projects options sheet including creation, folder actions, and layout choices.
- A fresh npm install of `mindwire@0.1.45` installed a working CLI, imported the
  public SDK, verified the release catalog checksum, downloaded the matching
  daemon, and booted it with isolated workspace/state/cache directories.
- The runtime and console images contain Linux amd64 and arm64 manifests. Each
  image's `latest` digest matches its `0.1.45` digest.
- This Mac's global CLI and running service both report `0.1.45`. The service
  update preserved its computer ID and SSH fingerprint. No agent turn was
  running; the update closed one idle terminal.

Screenshots:

- [Server home with parent navigation](server-home.png)
- [Server filesystem root](server-filesystem-root.png)
- [Conversation retained while inactive](inactive-chat-keeps-messages.png)
- [Outline Projects menu](projects-outline-menu.png)

The computer and Mindwire service must remain running. These checks do not claim
24 days of wall-clock testing or execution while the computer is asleep.
