# Interface icons

Mindwire uses a bundled PNG catalog for app-owned interface glyphs. `AppIconName` is the typed ID; `AppIcon` is the shared SwiftUI renderer. Navigation, toolbar actions, native menus, chat tools, authentication, source control, file management and desktop controls use this catalog.

```swift
AppIcon(.terminal).font(.body).foregroundStyle(Palette.accent)
AppIcon(.project, size: 24) // A fixed image slot, independent of the surrounding font.
Label("Files", icon: .folder)
Button("Refresh", icon: .refresh) { refresh() }
DestructiveButton("Delete", icon: .trash) { confirmDelete = true }
```

Use the existing semantic ID when actions mean the same thing. Catalog IDs are compile-time checked; there is no runtime SF Symbol fallback or icon CDN. Controls with context-specific actions should set their own accessibility label. Standalone glyphs have descriptive defaults; icons inside `Label` are decorative so VoiceOver reads the action title once.

## Rendering

The default artwork is the outline selection used by Openship, with additional desktop, keyboard and chat glyphs from the supplied PNG library. Filled selection and stop glyphs retain their meaning. Original source PNGs and filenames are copied unchanged; SHA-256 checksums record their provenance.

Agents uses the brain mark, Workspaces uses stacked layers, and Settings uses horizontal sliders. Projects uses the filled code-folder from the supplied catalog, including the tab, creation action, and default project artwork. Terminal actions use the unboxed prompt. Content icons use a 22-point canvas alongside standard 17-point body text, scaling proportionally with the surrounding font and Dynamic Type. This applies to labels, buttons, authentication, settings and workspace actions without individual size overrides. Project tools use this default; transcript tools and file edits use 18-point artwork in a shared 20-point column alongside their smaller labels. Source Control uses 22-point Monokai file glyphs in a 24-point column, scaling with Dynamic Type to match File Explorer. Per-file actions live in the native long-press menu and swipe actions. File Explorer uses the filled folder variant in list and grid views; tree folders use only the disclosure arrow, retaining the existing column widths and padding.

The app sets iOS 26's native `labelIconToTitleSpacing` to the shared 12-point spacing. Entity rows use the same gap. Project folders use a 36-point preview in rows and a 44-point preview in grid tiles so their four custom thumbnails remain legible; regular entity icons retain their existing column size. File Explorer's list uses a 10-point gap with its existing fixed icon column. Measure from the cropped artwork before changing layout spacing. Native labels keep their menu, toolbar and accessibility behavior; no negative icon margins or custom label layouts are needed.

Use `AppMenu` and `appContextMenu` for actions. They wrap the native SwiftUI menu and apply a fixed 22-point icon canvas only to its contents. The reserved icon column uses the same size, and fonts inherited from a file preview or row cannot enlarge menu artwork. The trigger and context-menu preview keep their normal sizing. Compact agent status labels use 14-point artwork with a 4-point gap and their own icon column.

Header controls use `AppToolbarItem` / `AppToolbarItemGroup`, which preserve native toolbar placement and hit targets while applying the `.toolbar` icon context. Their custom glyphs are two points smaller than their resolved size, including explicit sizes. Only top-bar, confirmation, and cancellation placements use this wrapper. Principal logos, content and file icons, bottom toolbars, and composer controls keep their original metrics. Menu contents explicitly restore the `.menu` context, so opening a header menu does not shrink its action icons.

Measured alpha bounds crop the original PNG's transparent padding. The rendered canvas keeps only one physical pixel around the artwork for edge filtering; there is no default optical inset added on top. An individual catalog entry can declare an optical inset when needed. The shared renderer uses native template images, so the surrounding tint controls light/dark appearance, secondary emphasis and destructive colors. Font resolution follows the existing SwiftUI font and Dynamic Type. Directional navigation symbols mirror in right-to-left layouts; code and terminal artwork do not.

Normalized bitmaps are cached by glyph, pixel size and direction, with a 512-image / 12 MiB cache limit. A tint change reuses the same bitmap. There are no network requests, background workers or per-row disk scans. Use `size:` for fixed artwork dimensions such as tab icons and composer controls; it overrides font and image scaling. `resizable()` is available for views that already own a fixed image slot.

`InterfaceIcons.xcassets` belongs only to the main app, not the notification extension. Provider/agent logos, custom project images and the existing Monokai file-type marks keep their dedicated rendering. The macOS workspace mark uses the native `apple.logo` symbol. System-owned navigation indicators, keyboards, alerts, progress spinners and text selection remain native iOS controls.

## Updating artwork

The reviewed selection is `scripts/icons/catalog.json`. Each entry declares the source filename, source collection, original checksum, optical inset and accessibility label. To choose new artwork, inspect its pixels before changing the catalog; similar filenames can represent different shapes or weights.

From the repository root:

```sh
swift scripts/icons/import.swift /path/to/png-icons /path/to/openship/apps/dashboard/public/icons
python3 scripts/icons/audit.py
```

The importer validates all selected sources before writing assets and generates `AppIconName.swift` with measured alpha bounds. Normal app builds use the checked-in assets and do not need either source directory. Do not import the whole source library.

The current catalog has 125 PNGs, totaling 270,349 bytes: 123 come directly from the supplied collection, including the pull-request mark. The disk and horizontal ellipsis are the existing Openship fallback artwork; their license is bundled as `InterfaceIcons-LICENSE.txt`.

## Verification

`scripts/icons/audit.py` checks asset completeness, original checksums, duplicate files, template configuration and app-wide catalog use. `AppIconTests` checks visible artwork, transparent margins, bitmap reuse, font/Dynamic Type sizing, tint, RTL, and native menu/tab images. Its light/dark catalog sheets support visual review. Existing project, chat, workspace, Git and authentication screen tests check the icons in their actual layouts.
