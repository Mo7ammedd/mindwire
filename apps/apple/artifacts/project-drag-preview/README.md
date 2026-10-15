# Direct project reordering — October 7, 2026

Project and folder menus no longer offer a separate Reorder action or editing mode. Holding and dragging a card keeps the normal toolbar and saves the existing custom order. List cards own their background and disclosure inside the lift preview; the spacing between rows stays outside it. Grid previews use the same rounded outline.

All screenshots use fictional, isolated project-library fixtures. No real project, workspace or account was edited.

| Check | Result |
| --- | --- |
| Signed device and simulator builds | Passed |
| iPhone 12, iOS 26.5.2: direct list/grid dragging and order across relaunch | 2 passed |
| iPhone 17 Pro Max simulator: project/folder dragging, menus and saved order | 4 passed |
| iPad Pro 13-inch simulator: project list/grid dragging and saved order | 2 passed |

The physical-device test initially could not start because Xcode authentication was canceled. After device authorization, both project tests passed. The iPad folder check exposed a native drop that lifted the card but snapped back on release, including with an explicit insertion point. List and grid folders now share the existing app-local drag handler and save only on a completed drop.

The final regression run passed on both iPhone and iPad simulators, including dragging a folder, opening and dismissing its context menu, dragging again, switching layouts, and opening a member project. Grouped cards keep the same appearance in a lazy scroll view; flat project lists retain native list reordering. The extended test allows for iOS 26 XCTest's context-menu animation waits; this changes the test deadline only.

Two new navigation checks also passed on the physical iPhone: repeated project taps in list/grid after recency changes, and opening projects inside a folder then returning with one Back. Folders now share the project navigation path, and iPad destinations inherit sidebar selection, so a folder stays in the sidebar while its project opens in the detail column.

## Reviewed captures

| State | Capture |
| --- | --- |
| List card during a drag, dark | [View](list-drag-dark.png) |
| Grid card during a drag, light | [View](grid-drag-light.png) |
| Physical iPhone list | [View](device/32604D07-25E4-4351-9791-97465BE5FED2.png) |
| Physical iPhone saved order | [View](device/FD5DED01-95F5-40D2-AD70-AC1E932AFEA7.png) |
| Project context menu | [View](iphone/E7AC3FEB-1C09-415D-8749-90D5EBFC1825.png) |
| Project options | [View](iphone/6FC30229-433C-40C7-AA7E-FA695F1E9D99.png) |
| iPad list | [View](ipad/list/08E73AAA-0FCF-4F55-B4DD-4C42F0E59090.png) |
| iPad grid | [View](ipad/grid/611D08F7-424D-48B0-8E03-ECCEEA60B578.png) |
| Final iPad folder and selected project | [View](final/ipad-folder-project.png) |
| Final folder menu and rounded preview | [View](final/ipad-folder-menu.png) |

The two moving-card images are unedited frames from a native simulator screen recording. iOS supplies the lift shadow, drag opacity and drop animation. Xcode attachment manifests accompany the other captures.

Local result bundles:

- `/tmp/MindwireProjectDirectDragDeviceReady-20261007.xcresult`
- `/tmp/MindwireProjectDirectDragIPhone-20261007.xcresult`
- `/tmp/MindwireProjectDirectDragIPad-20261007.xcresult` — project checks passed; the native folder drop failed before the shared-handler fix.
- `/tmp/MindwireFolderFinal360-iphone-20261007.xcresult` — final extended folder drag and navigation flow passed.
- `/tmp/MindwireFolderFinal360-ipad-20261007.xcresult` — final extended folder drag and navigation flow passed.
- `/tmp/MindwireVoiceAndNavigationDeviceFinal-20261007.xcresult` — both physical project-navigation checks passed, alongside the independent audio attachment transfer check.

The tested build is installed and the regular app is open on the physical iPhone. The folder and navigation fixes require only the app update.
