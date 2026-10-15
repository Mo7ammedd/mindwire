# Store artwork logos

These small PNGs are rasterizations of the existing vector agent marks in `apps/apple/Mindwire/Resources/Assets.xcassets`: `agent-codex`, `agent-claude-code`, and `agent-opencode`. They retain the original silhouettes and are used as monochrome logos beside feature copy, outside the captured app interface. Brand ownership and attribution remain with their respective owners.

`mindwire.png` is rasterized directly from the app’s `OblienMark.svg`. The compositor trims the asset’s transparent padding, uses its original silhouette, and pairs it with the **MindWire** wordmark.

No fonts, generated app UI, or third-party device photographs are bundled. The device frames and background artwork are drawn by `design.py`. XCTest omits the physical sensor mask, so the frame includes Dynamic Island in the iPhone 17 Pro Max's reserved status-bar area.
