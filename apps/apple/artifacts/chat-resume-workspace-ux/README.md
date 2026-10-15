# Chat recovery and workspace UX — 2026-10-07

The updated app was built and installed on the connected physical iPhone 12 (iOS 26.5.2). These captures use the production screens with isolated, fictional preview data. No App Store upload or daemon restart was performed.

## Changes

- Every workspace card supports a native long-press menu. Open, project creation, rename, deletion and paired-computer recovery reuse the workspace's existing controls. New Project retains the selected workspace.
- Creating within a project folder preserves the current folder navigation, including after optional agent setup. Unscoped creation still opens the accepted project.
- Errors start as one title row. Expanded text is limited to six lines, with the complete selectable diagnostic available in a native sheet. Rejected sends retain the draft and show a dismissible error above the input, without an automatic alert.
- Reopening an active cached chat keeps its received reply visible. After checking run status, it subscribes after the last applied event instead of rereading native history or downloading the same snapshot. Completed/changed runs use a bounded newest history page. Partial replay, sequence gaps, duplicate opens, cancellation and old daemons retain safe recovery paths.

## Validation

| Check | Result |
| --- | --- |
| ChatFeed, ChatLifecycle, ChatQueuedInput, ChatReconnection, ChatRun and ProjectStart suites | 120 tests passed on iPhone simulator |
| InteractionProtocol suite | 8 tests passed after correcting the test window's UIKit dark appearance |
| Physical iPhone UI: collapsed/expanded errors in both themes, full diagnostics, rejected-send draft, menus on all three workspace types, workspace selection and rename | 4 tests passed |
| iPad simulator UI: error disclosure, workspace menus, empty-folder creation and the all-organized project picker | 4 tests passed |
| Simulator and device builds; whitespace validation | Passed |

The first protocol appearance run exposed two snapshot tests drawing dark-mode text over a light UIKit backing view. Matching the backing appearance corrected those fixtures; all eight protocol tests then passed. No assertions were removed.

Chat recovery tests use the production model, session and transport with controlled HTTP/event fixtures. They verify 400 unseen deltas, one shared subscription, no repeated history/snapshot request for the cached run, replay interrupted by navigation or a network disconnect, finished/newer runs, native CLI history changes, queued inputs and Stop/send races. They do not run paid model inference.

An additional physical-device rerun of the already-passing model/folder checks was canceled before launch when the iPhone locked. It is not counted above. The completed iPhone UI run and iPad folder checks passed.

Local result bundles:

- `/tmp/MindwireChatResumeCore-20261007.xcresult`
- `/tmp/MindwireChatResumeForms-20261007.xcresult`
- `/tmp/MindwireChatResumeDeviceUI-20261007.xcresult`
- `/tmp/MindwireChatResumeIPadUI-20261007.xcresult`

## Reviewed captures

- [iPhone: collapsed error, dark](iphone-error-collapsed-dark.png)
- [iPhone: collapsed error, light](iphone-error-collapsed-light.png)
- [iPhone: bounded error details](iphone-error-expanded-light.png)
- [iPhone: rejected send preserves draft](iphone-rejected-send.png)
- [iPhone: workspace context menu](iphone-workspace-menu.png)
- [iPhone: workspace renamed](iphone-workspace-rename.png)
- [iPad: workspace context menu](ipad-workspace-menu.png)
- [iPad: error preview](ipad-error-expanded-dark.png)
- [iPad: empty folder](ipad-empty-folder.png)
- [iPad: all projects organized](ipad-organized-projects.png)
