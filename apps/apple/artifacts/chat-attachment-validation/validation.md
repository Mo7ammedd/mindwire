# Chat attachments and Stop → Send

6 October 2026.

## Implementation

- Sent photos and file cards sit above the message bubble. Photos open in the image viewer; files use a native preview with a fixed Done button.
- The attachment menu offers Photo Library, Take Photo and Choose Files. Document-provider reads are coordinated, uploads report progress, and durable references survive history reload, forks and project transfer.
- Command previews are bounded to 12 lines and 4,000 characters. Full output reuses the read-only file editor in a sheet with fixed Done and Copy controls. The header, footer and context menu can collapse a tool call.
- Stop blocks new admission until cancellation settles. An upload crossing Stop is prevented from starting another turn; an already-admitted request is cancelled by its exact returned run ID.

## Completed checks

- Native installed Codex and Claude, through the production daemon API and isolated local model fixtures: image input, reading attached files, queued messages, deduplicated history, and file retention after forking and deleting the source chat.
- Native Codex fixture: 700 KB file upload/read, stop during a running turn, then immediate send into the same native conversation.
- Go race tests, vet and build passed. The separately authenticated external TestLiveClaude check was excluded locally; the new native fixture checks passed. All GitHub PR and release gates passed.
- TypeScript SDK typecheck/build and 207 tests passed (20 opt-in skips). The website production build generated 910 pages.
- Published npm 0.1.44: verified daemon download and checksum, capability flags, 16 MiB chunked upload with progress, byte-for-byte readback, and artifact cleanup after chat deletion.
- Runtime and console 0.1.44 images contain Linux amd64 and arm64 manifests; each latest alias matches its version tag.
- The Mac CLI and live service now report 0.1.44 with file-upload and queued-input capabilities. Computer identity and SSH fingerprint are unchanged.
- The signed iPhone build-for-testing passed, and the updated app was installed on the connected physical iPhone 12.

## Physical iPhone checks

- The physical iPhone sent a photo and a 700 KB file through the production paired SSH connection into an isolated native Codex session. File contents, durable history references, Stop during the native response, and immediate Send passed. Evidence: `/tmp/mindwire-attachments-physical-native.log` and `/tmp/mindwire-attachments-physical.xcresult`. The native session used a local model fixture and did not modify the user's chats.
- All seven interaction cases passed across the approved and final targeted UI runs: sent image and file placement, image/file previews with Done, Photo Library and Files pickers, tool collapse through its header/footer/context menu, Codex/Claude loading-state and transcript keyboard dismissal, and queued input with Stop recovery. Camera availability was checked in the attachment menu; no personal photo was captured.
- The long-output case opens 10,000 lines in the shared file editor and keeps Done available during scrolling. Inner controls have independent accessibility identifiers.
- Six image/attachment tests and four queued-input reconciliation tests passed. The final cache/lifecycle/presentation unit phase passed 65 tests, including cached attachment recovery after session binding and Stop/upload races.
- Native UI screenshots were inspected. The final app was installed and launched normally on the physical phone. No simulator was substituted.

Evidence: `/tmp/mindwire-chat-ui-approved.xcresult`, `/tmp/mindwire-chat-tools-final.xcresult`, and [cached-chat validation](../chat-catchup-validation/validation.md). The first UI run exposed the tool-header identifier problem; the final targeted UI run passed after fixing it and replacing the slow full-log text view.

## Screenshots

- [Images and files above the message](sent-attachments-iphone.png)
- [Native file preview](file-preview-iphone.png)
- [Full command output](full-command-output-iphone.png)
- [Collapsed command](collapsed-command-iphone.png)
- [Codex loading](codex-loading-iphone.png)
- [Claude loading](claude-loading-iphone.png)

[Merged PR #32](https://github.com/oblien/mindwire/pull/32) · [Release 0.1.44](https://github.com/oblien/mindwire/releases/tag/v0.1.44) · [Successful release CI](https://github.com/oblien/mindwire/actions/runs/37418754048)
