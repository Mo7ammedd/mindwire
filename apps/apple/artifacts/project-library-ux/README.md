# Project library UX

Captured from the real SwiftUI screens with fictional, offline projects on iOS 26.5 simulators (2026-10-05).

| Screen | iPhone 17 Pro Max | iPad Pro 13-inch (M5) |
| --- | --- | --- |
| Grid, light | [View](iphone-grid-light.png) | [View](ipad-grid-light.png) |
| Grid, dark | [View](iphone-grid-dark.png) | [View](ipad-grid-dark.png) |
| Folder previews | [View](iphone-folder-grid-light.png) | [View](ipad-folder-grid-light.png) |
| Inline native reorder | [View](iphone-reorder-dark.png) | [View](ipad-reorder-dark.png) |
| Folder membership | [View](iphone-members-light.png) | |
| List / selected project | [View](iphone-list-light.png) | [View](ipad-folder-project-light.png) |

List reordering starts with **Hold card → Reorder** or **Options → Reorder**, then uses native handles on the current screen. Grid cards also support direct dragging. Layout and order survive relaunch. New folders offer only unassigned projects; editing a folder separates existing members from available projects.

Validation passed: 35 project/library/layout regression tests and five native interaction flows on each device. The final iPad card-background adjustment was checked again with the folder-navigation and inline-reorder flows.
