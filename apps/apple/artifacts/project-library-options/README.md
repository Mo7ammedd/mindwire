# Projects options and folder previews

Captured from the production SwiftUI screens with fictional, offline projects on iOS 26.5 simulators (2026-10-06).

One toolbar button opens the native options sheet. New Project comes first; creation actions dismiss this sheet before opening their destination. Layout, grouping, and sorting update in place. Reorder returns to native handles in the existing list.

| Screen | iPhone 17 Pro Max | iPad Pro 13-inch (M5) |
| --- | --- | --- |
| Options, light | [View](iphone-options-light.png) | [View](ipad-options-light.png) |
| Options, dark | [View](iphone-options-dark.png) | [View](ipad-options-dark.png) |
| Folder actions | [View](iphone-folder-options-dark.png) | [View](ipad-folder-options-dark.png) |
| Folder list, light | [View](iphone-folder-list-light.png) | [View](ipad-folder-list-light.png) |
| Folder list, dark | [View](iphone-folder-list-dark.png) | [View](ipad-folder-list-dark.png) |
| Folder grid, light | [View](iphone-folder-grid-light.png) | [View](ipad-folder-grid-light.png) |
| Folder grid, dark | [View](iphone-folder-grid-dark.png) | [View](ipad-folder-grid-dark.png) |
| Partial folder previews | [View](iphone-folder-partial-grid-light.png) | [View](ipad-folder-partial-grid-light.png) |
| Inline reordering | [View](iphone-reorder-dark.png) | [View](ipad-reorder-dark.png) |

Cards and grid tiles share up to four cached custom project images. Missing custom images leave unused slots empty; a folder with no custom images uses one filled folder glyph. The Studio project demonstrates the new filled code-folder default from the supplied icon catalog.

Validation passed: 11 icon and project-presentation regression tests, five library interaction flows on iPhone, and four on iPad. The sheet transition and sizing check passed again on both devices after the final adjustment, including a check that Delete Folder is immediately reachable. The interaction checks also cover single-folder membership, layout/order persistence, native dragging, rename, moving projects between groups, and deleting folders without deleting their projects.
