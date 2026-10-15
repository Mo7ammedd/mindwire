# Cached conversation catch-up

6 October 2026. Physical iPhone 12, iOS 26.5.2. No simulator substituted.

## Behavior

- Returning to a cached conversation revalidates its newest native page, including work done in the computer's CLI without a push notification or a new daemon run.
- A compact cached tail stays visible with the harness logo and “Loading latest…” indicator. The new page replaces the stale window and supplies its own older-history cursor.
- Positioning goes directly to the latest row. Intermediate pages load only when the reader scrolls up. Concurrent opens share the in-flight request.
- Reopened or restored runs finish with the newest native page instead of downloading back to the beginning of the run. Native messages remain authoritative, and older cached tools are not appended beneath the newest answer.
- The table settles late cell measurements without an idle display timer. Manual scrolling and disclosure expansion retain the reader's position; keyboard and composer insets leave the final line visible.
- Removing or evicting a model cancels its reads without generating a new navigation request.

## Validation

The physical-phone unit phase completed 65 checks with zero failures: ChatLifecycleTests (47), ChatFeedTests (9), and ChatPresentationTests (9). Evidence: `/tmp/mindwire-chat-catchup-final.log` and `/tmp/mindwire-chat-catchup-final.xcresult`. The later UI phase of that combined run was interrupted to replace the slow full-log text view; the final UI rerun is recorded below.

The controlled catch-up scenarios cover:

- Native history advancing from 60 to 400 messages after leaving the screen, with no activity notification and within the old cache TTL. Reopening makes one shared newest-page read, displays the latest 12 messages, and can then page upward from the new cursor.
- A run completing while the phone is away, and a restored run completing after hundreds of native messages. Both avoid intermediate-history backfill and duplicate old live output.
- Reopening a long running transcript, visible final output, no automatic older-page fetch from layout, and a stable table through catch-up.
- Manual scrolling while output arrives, notification positioning, keyboard safe areas, Stop during a slow refresh, immediate Stop → Send, and attachment loading after the daemon session becomes available.

These use deterministic daemon-channel fixtures on the physical phone. The separate native Go history API test also passed: its bounded warm page was 640,606 bytes versus the older 12,811,112-byte page. Complete oversized messages remain supported by the API's soft byte limit; no constant network-latency guarantee is implied.

Physical tap tests passed in `/tmp/mindwire-chat-ui-approved.xcresult` and the final `/tmp/mindwire-chat-tools-final.xcresult`: image/file previews, Photo Library and Files pickers, Codex/Claude loading and keyboard dismissal, queued input and Stop recovery, and header/footer/context-menu collapse of a 10,000-line command. The final two-test UI run exited successfully.

The final signed app was installed and launched normally on the connected iPhone. This change uses the existing Mindwire history API and does not require another daemon release.

## Screenshots

- [Cached tail with loading indicator](loading-latest-iphone.png)
- [Reopened directly at the newest page](newest-page-iphone.png)
- [Running chat reopened at current output](running-chat-reopened-iphone.png)
- [Final line above the keyboard safe area](keyboard-safe-area-iphone.png) — the test supplies a blank native input view to measure keyboard insets.
