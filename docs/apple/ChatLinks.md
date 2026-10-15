# Chat links

Markdown links in a conversation open in the app. HTTP and HTTPS destinations use the shared `SFSafariViewController`. File links use the conversation's project and its existing workspace connection, then open the same `FilesSheet` and `FileEditorScreen` used by project tools. Closing a preview does not dispose the chat's session.

Relative paths resolve against the project directory. Absolute paths, workspace home paths, `file:` URLs, and absolute `sandbox:` paths resolve on that workspace. URL escapes are decoded once. Codex's `file.swift:12:4` citations and `#L12` / `#L12-L20` fragments open the referenced line without entering edit mode. An explicit link outside the project can browse its containing directory, with the filesystem root available above it.

An on-demand, safely quoted filesystem check distinguishes a folder from a file. Directories open in the existing browser; raster images open in its zoomable image viewer; code opens in its native editor. Missing files and inaccessible workspaces show recovery UI. Links never execute arbitrary app URL schemes or use the phone's filesystem. Files are only requested after a tap, and repeated taps cannot stack presentations or duplicate an active lookup.

Previews opened from chat include Done in the editor and nested folders. It closes the preview directly, retaining the file workbench's existing unsaved-edit confirmation.

Standalone local Markdown images render a compact Preview action. Opening it uses the existing bounded image reader instead of downloading workspace images while chat rows render. Network images retain MarkdownUI's image provider.

`ChatSelectableText` forwards native text link actions through SwiftUI's `openURL`, including the native link menu. The virtualized transcript explicitly bridges that action across its `UIHostingConfiguration` boundary and reads the current context when tapped; cached cells do not retain an old project's routing. Rendered text selection remains independent.

`ChatLinkTests` covers path resolution, citations, remote home paths, escaped and non-Latin filenames, web queries/fragments, and unsupported schemes. `ChatLinkInteractionTests` exercises real transcript link taps into the existing file editor, image viewer, folder browser, and in-app Safari using an isolated workspace fixture.
