# Source Control header and first-scroll work — 8 October 2026

A permanent native safe-area bar now extends the navigation area. It shows branch controls at the top and the active section's folder/actions while scrolling, with exactly the same reserved height. Its background matches the navigation and file list; the native fade starts below it. The overview combines totals and Files / Review without the former branch capsule and separate footer gaps. Inline section headings scroll normally instead of adding another pinned layer.

The shared tree flattens prepared snapshot branches into descriptors and gives every native List item an explicit one-row container. The previous recursive/conditional view structure evaluated 2,216 rows before scrolling in the 1,098-file iPhone fixture. Files and prepared Git rows no longer schedule empty directory-loading tasks. Folder paths update only the context bar; scrolling does not rebuild the prepared tree or alter its insets.

The focused simulator check passed, including initial row creation, cold short drags, both scroll directions, independent horizontal breadcrumb scrolling, long paths, navigation placement, and folder collapse/reopen. It created 66 row views initially and 189 across the measured scroll sequence, rather than the entire tree. Tree body/build counts stayed at 12/2, the top inset stayed at 122 points, and the tracker inspected at most 28 visible cells, averaging 61 microseconds per scan. A separate existing stage/unstage check also passed after the shared row-container change.

The fixture-only display-link probe recorded a maximum first-drag callback interval of 33.3 ms in the simulator. There was one longer callback interval (87.5 ms) later in the sequence. These are main-run-loop timing observations under UI automation, not a guarantee of rendered frame rate. This sampler never runs in normal app sessions and stops when the fixture is not scrolling.

Results:

- `/tmp/mindwire-native-context-lazy-simulator-20261008.xcresult` — one focused scroll/collapse check passed.
- `/tmp/mindwire-native-context-actions-simulator-20261008.xcresult` — one inline stage/unstage check passed.
- [Current simulator counters](simulator-scroll-counters.txt).
- Current simulator captures: [continuous header](simulator-continuous-header-dark.png) and [compact overview](simulator-compact-overview-dark.png).
- [iPhone baseline before lazy row creation](before-lazy-rows-device-counters.txt).

The final build is installed on the iPhone (installation confirmed at 06:07). The device run could not launch while the phone was locked; the queued run was canceled after waiting for unlock. Final physical-device timing and captures remain pending. Existing iPhone images and `device-scroll-counters.txt` still show the preceding pinned-section implementation and do not validate this final header.
