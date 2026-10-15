# Chat links — October 8, 2026

These captures use the production chat, file editor, image viewer, and Safari presentation on an iPhone 17 Pro Max simulator running iOS 26.5. The project and image are isolated fixtures, with no personal workspace files. The browser capture shows its native loading state immediately after opening the real Mindwire documentation URL.

- `source-link.png`: a relative source citation opened in the existing editor.
- `image-link.png`: a workspace PNG opened in the existing image viewer, with Done to return directly to chat.
- `web-link.png`: a web link opened in the native in-app browser.
- The compact Source Control tree is captured in `../navigation-source-control/tree-compact-iphone-dark.png`.

Three path-routing unit tests passed, covering relative/absolute/home paths, citations, URL escapes, Arabic filenames, web links, and unsupported schemes. The focused UI check passed for source, image, folder, and web link taps and returning to the same conversation. The existing Source Control tree check passed for expansion/collapse, layout persistence, and opening diffs. No full suite was rerun.

The initial link check exposed nested folders lacking a direct close action. Chat previews now retain their normal folder navigation and also offer Done, using the existing unsaved-edit confirmation. The UI selectors also account for UIKit's nested link accessibility nodes and Safari's iOS 26 Close button.

The signed physical-iPhone build passed and was installed on the connected iPhone. The phone was locked for interaction checks; the UI results above are from the simulator.

Result bundles: `/tmp/mindwire-chat-links-verified-20261008.xcresult` contains the passing link interaction check. `/tmp/mindwire-chat-links-tree-20261008.xcresult` contains the passing path and tree checks alongside the superseded link-selector failure.
