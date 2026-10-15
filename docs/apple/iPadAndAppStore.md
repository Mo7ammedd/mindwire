# iPad layout and App Store captures

Mindwire adapts to the available **window**, rather than assuming every iPad has a full-screen landscape layout.

## App behavior

- Projects, Agents, and Workspaces show a sidebar when there is room. The detail navigation stack stays mounted as columns appear or disappear, retaining live chats, drafts, and back history. The sidebar can be hidden with its toolbar button or **Control–Command–S**.
- Wide project pages place chats beside project tools and location details. Narrow windows and larger accessibility text return to one column.
- Files use a native split view with the browser beside the editor. A narrow window pushes into the selected file. Changing files or closing the sheet protects unsaved edits with a native confirmation; **Command–S** saves.
- Source Control keeps the change list beside the selected diff. Staging and unstaging follow that same file to its new group. The iPad sidebar has a visible staged count and Commit action that does not compress into a narrow native toolbar slot. **Command–Return** opens Commit.
- Chat keeps its recycled UIKit transcript and a centered, readable composer. **Command–Return** sends. It does not request history again just because the window resizes.
- Forms and single-column details keep a readable width. File and source-control workspaces use page-sized iPad sheets.
- iPad supports all four orientations, including after closing a desktop. Desktop controls adapt to the viewport, with a touchpad beside or below the display.
- Touchpad controls use native surface colors so their labels remain readable in Light and Dark. Menu icons leave accessibility to their parent labels; decorative-image hiding no longer hides the native action.
- Each app window owns its navigation. All windows share a single foreground lifecycle for service checks, metadata, and notification subscriptions.
- System, Light, and Dark appearances are available; the application plist no longer forces Dark.

## Automated coverage

`iPadLayoutTests` checks the existing transcript/editor objects, read counts, draft retention, source-control staging, layout bounds, and orientation policy while changing widths between 600, 1032, and 1376 points.

`iPadInteractionTests` launches the real app in a simulator, types into the chat and editor, rotates the device, toggles the sidebar, and checks the unsaved-file confirmation. `AppLifecycleTests` verifies that multiple windows coalesce preparation and foreground work, with cancellation on backgrounding and renewal after an account change.

The existing ChatFeed, ChatLifecycle, GitReview, and PushNotification suites cover the affected scrolling, navigation, and cached-data behavior.

## Screenshot source

`Mindwire/Preview` is compiled only for **Debug simulator builds**. Launch argument `--app-store-preview` selects the offline preview; it never replaces a normal launch. Release and physical-device builds omit the fixture implementation.

The preview injects fictional data into the production views and their existing service interfaces. The desktop pixels come from an actual local HTML demo page rendered by WebKit and passed through the production desktop viewer. No remote server, real account, credential, project, or live chat is used.

The UI test captures six scenes in both appearances:

1. Agent chat
2. Projects
3. Source Control and diff
4. File editor
5. Remote desktop and touchpad
6. Switch Workspace

## Reproduce

Xcode 26, an iOS 26 simulator runtime, XcodeGen, and Python 3 are required. Use dedicated simulators so automation does not change a development simulator's app state.

Create a dedicated **iPhone 17 Pro Max** simulator (1320 × 2868) and **iPad Pro 13-inch (M5)** simulator (2064 × 2752 portrait / 2752 × 2064 landscape). Find their identifiers with `xcrun simctl list devices available`. Boot both before capturing.

```sh
python3 scripts/app-store/capture.py \
  --device IPHONE_SIMULATOR_ID --kind iphone \
  --derived-data /tmp/MindwireStoreBuild \
  --output apps/apple/artifacts/app-store/native/iphone

python3 scripts/app-store/capture.py \
  --device IPAD_SIMULATOR_ID --kind ipad --skip-build \
  --derived-data /tmp/MindwireStoreBuild \
  --output apps/apple/artifacts/app-store/native/ipad
```

The capture script runs the native UI test, sets the device orientation, applies a 9:41 status bar, waits for the actual content and finished visual transitions, and restores the status bar afterward. iPad orientation is baked into the PNG pixels rather than left in EXIF metadata. It retains logs, device metadata, and the `.xcresult` for inspection. For other native test devices, `--native-size WIDTHxHEIGHT` changes the capture assertion; the Store compositor deliberately requires the Pro Max and 13-inch iPad sources above.

For a selected feature, add `--scenes desktop,switch` or `--themes light`.

Compose the download set:

```sh
python3 -m venv /tmp/MindwireStoreTools
/tmp/MindwireStoreTools/bin/pip install -r scripts/app-store/requirements.txt
/tmp/MindwireStoreTools/bin/python scripts/app-store/compose.py \
  --captures apps/apple/artifacts/app-store/native \
  --output apps/apple/artifacts/app-store --zip
```

The compositor preserves the full app capture inside a device frame, with proportional downsampling. It converts to sRGB and exports opaque 8-bit RGB PNGs at **1284 × 2778** for iPhone and **2752 × 2064** for iPad. Native Pro Max originals retain their larger 1320 × 2868 dimensions in the `native` folder. It generates a local gallery/contact sheet and packages the output in `apps/apple/artifacts/Mindwire-App-Store.zip`.

The artwork uses the actual app logo beside the **MindWire** wordmark, SF Pro display typography, thin Pro hardware frames, and warm orbital lighting. iPad compositions give the native sidebar and detail layout their own landscape presentation. XCTest omits the physical sensor mask, so the iPhone frame includes Dynamic Island in the reserved status-bar area. Captured app content is not redrawn. Agent marks come from existing vector assets; system fonts are read from macOS and are not bundled.

`--allow-partial` is for design iteration only. A normal export fails if any of the 24 inputs is absent or has the wrong dimensions. Each appearance is a separate six-image set; select one or mix up to ten images in each App Store Connect device slot. No upload or publication happens automatically.

## Verification

The capture run covers all six screens in Light and Dark on both dedicated devices. The iPad interaction checks cover portrait/landscape, keyboard input, sidebar toggling, dirty-file protection, saving, and the light-mode Commit action. Layout checks also exercise narrow and wide windows. The regression run includes AppLifecycle, AppIcon, ChatFeed, ChatLifecycle, GitReview, and PushNotification coverage.

Validate the final upload inventory against `manifest.json`: 24 composed PNGs, the required dimensions, RGB color, embedded sRGB profiles, and upright pixels. Keep the 24 native originals in the archive for future artwork changes. The optimized device build must omit `--app-store-preview` and all offline fixture code; only Debug simulator builds include the capture entry point.

Final validation on 2026-10-05 passed: four iPad layout tests, three native iPad interaction tests, both complete device capture runs, the optimized arm64 Release build, and all 48 PNG integrity/profile/orientation checks. The Release binary supports both device families, all four iPad orientations and multiple windows, and contains no capture-fixture markers. Gallery references and ZIP checksums also passed.
