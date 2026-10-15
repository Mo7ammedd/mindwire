# Harness questions and approvals

The daemon owns the interaction protocol and native harness mappings. Its canonical
contract is [Mindwire's INTERACTIONS.md](https://github.com/oblien/mindwire/blob/main/packages/daemon/INTERACTIONS.md).
The iOS app renders the normalized data; it does not inspect Codex or Claude output.

`DaemonInteraction`, `DaemonQuestion`, `DaemonQuestionAnswer` and
`DaemonInteractionReply` in `Models/Daemon.swift` mirror the daemon contract.
`InteractionView` renders grouped questions, one or multiple selections, native
descriptions, previews, optional feedback, secret answers, and offered approval actions.
Both harnesses use that same view and `ExecDaemonTransport.respondToRun` path over
either an SSH channel or the Oblien runtime proxy.

`ChatModel` answers native control requests in the active run. It also answers
`responseMode: "message"` forms in history using their daemon `runId`. Codex async
questions use this mode: the daemon steers a running turn or resumes the conversation,
and owns validation, persistence and duplicate prevention. The app does not compose
harness-specific answer text or start the continuation itself.

Duplicate taps are disabled while submitting; failed requests retain their answers
for retry. A chat-owned draft retains selections while an async form moves from live
output into history. Reopening restores pending forms and accepted choices from the daemon.
Historical native controls and resolved forms are read-only. Blocking requests show
waiting status; async forms explain that the agent can continue while the user chooses.

Questions trigger the daemon's existing `waiting_feedback` notification route. Chat
and agent mutes still apply. iOS suppresses alerts for the currently visible chat and
continues to show alerts for other chats, including those belonging to the same agent.

Quick settings come from the daemon's schema and canonical field keys. Changes stay
in a local draft until Done. A live Claude permission change must be acknowledged by
the native harness before the app saves it. Codex settings apply on the next turn,
as its native protocol specifies; the sheet explains that behavior.

`InteractionProtocolTests` decodes forms captured from real Codex and Claude runs,
checks answers and transport payloads, and renders both forms through the native
SwiftUI component. `ChatLifecycleTests` covers a grouped form after reconnect,
duplicate submission, rejection/retry, and completed history.

These changes require both the updated app and a new daemon release. A previously
installed daemon cannot provide grouped forms or native control acknowledgements
through an app update alone.
