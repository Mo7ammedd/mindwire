# Switching a project between workspaces

Open a project's menu and choose **Switch Workspace**. The app reuses the workspace-card picker and folder browser. The first switch selects a destination folder; later switches recognize that workspace's existing copy.

**Files to Transfer** shows the selected working-file count/size and Git ignored paths. Ignored folders such as `node_modules` stay on their own workspace by default. Open the review to include an ignored file/folder, or use **Include a Path** for a specific child. Tracked files and non-ignored unfinished work remain included. Git history and chats are additional to the working-file estimate. Dependencies can be installed from the lockfile on the destination; switching does not run installation scripts.

The daemon uses native Git ignore rules and prunes excluded directories before reading their contents. The preview does not hash/upload files. A scope token binds the transfer to that review; changing ignore rules or tracked paths requires **Review Transfer** before a new operation can start. The app cancels stale previews and persists the acknowledged selection with each transfer, including after relaunch.

Pending transfers from an older app require a fresh review before relaying more content. Checkpoints already accepted by the destination can finish without reopening the source.

Mindwire services own project checkpoints, native history export/import, conflict detection and recovery. The app relays verified chunks through its existing authenticated workspace transport. There is no additional cloud storage service and no mobile-owned shadow chat history.

Both workspace copies remain. Compatible changes and additional chats come back on the next switch. Excluded files are never treated as deletions, so each workspace's local dependencies and configuration remain intact. Even old full checkpoints are filtered before relay. Independent changes that conflict stop before applying; the sheet lists the affected paths and offers Retry after resolution. A running turn or terminal must finish before the project can switch.

Transfers outlive the sheet. iOS background time is finite: expiry pauses the relay, while an accepted destination transaction continues in its service. Relaunch/foreground resumes missing content with the same operation IDs. Brief transport failures get bounded retries. Once the destination has accepted the checkpoint, completing the switch does not require the source online.

`ProjectSyncCoordinator` persists intent and progress only. The destination's acknowledged registry snapshot creates the local cache records and selects the new copy. Logical `syncId` groups copies into one Projects-tab card, while workspace views retain both. Conflicts never select or open a destination. Changed daemon registry identities stop stale transfers.

Version 2 requires updated Mindwire services on both macOS/Linux workspaces and supports native Codex/Claude histories. The app refuses older services that could silently copy ignored dependencies. Destination logins and global harness settings remain workspace-local. Unsupported repository/native formats stop explicitly instead of omitting context. The daemon's [protocol and preservation contract](../../packages/daemon/PROJECT_SYNC.md) describes the supported data and limits.

Validation: `ProjectSyncTests`, `ProjectPresentationTests` and `WorkspaceDataTests` run on the iOS simulator. Daemon tests additionally run real Codex/Claude native X → Y → X conversations through authenticated HTTP with isolated homes and local model fixtures. These tests do not modify paired computers or personal harness data.
