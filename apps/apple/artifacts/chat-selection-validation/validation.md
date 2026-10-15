# Rendered chat selection and project activity

2026-10-06. Physical iPhone 12, iOS 26.5.2. Screenshots use fictional fixture
conversations, without personal notifications or workspace content.

Project cards and conversation loading share `AgentActivityGlyph`: the bundled
harness artwork sits inside the same animated ring. Project cards place it in
the existing right accessory area, in both list and grid layouts. Cached
disconnected activity and Reduce Motion pause animation.

Chat paragraphs, headings, table cells, code blocks and user text use native
read-only text views for word selection. MarkdownUI retains its block layout
and image handling. The native text menu also exposes the original raw text
and, where available, Edit and resend. A selected Markdown message stays stable
while the model receives new output; ending selection reveals the latest text.

Passed on the physical iPhone:

- Double-tap a bold rendered word, Copy, and Paste into the composer. The pasted
  result was exactly `selection`, without Markdown delimiters or surrounding text.
- Taps on messages, tool headers and blank transcript space dismiss the keyboard
  while preserving the draft and keeping tool disclosure actions working.
- Arabic paragraphs and composer alignment, with left-to-right code blocks.
- Native attributed-text checks for emphasis, links, inline code, Unicode syntax
  ranges, literal user text and paragraph writing direction.

The final physical-device gesture run passed all five tests. Long-press opens
the original raw Markdown from Select Text, attachments remain above sent text
with a working native preview, and project activity rings render in light and
dark list and grid layouts. The Projects tab uses the outline catalog artwork,
and the toolbar uses the outline More circle. The latest project captures show
custom icons only: a project without custom artwork starts with its name, with
no fallback glyph or reserved icon column. Grid cards keep their common size
and put the text at the top when there is no custom icon.

All 64 chat unit tests passed on this iPhone, including preserving a selected
rendered message while streaming updates continue, lifecycle and queued-send
state, keyboard dismissal, and attributed-text selection.

Evidence:

- [Native rendered-word selection](rendered-word-selection.png)
- [Arabic paragraphs and code](arabic-rendered-text.png)
- [Raw Markdown selection](raw-markdown-selection.png)
- [Project rings — dark list](project-ring-dark-list.png)
- [Project rings — dark grid](project-ring-dark-grid.png)
- [Project rings — light list](project-ring-light-list.png)
- [Project rings — light grid](project-ring-light-grid.png)
- [Projects options — dark](projects-options-dark.png)
- [Projects options — light](projects-options-light.png)
- [Sent image and file above message text](sent-attachments.png)

Final UI results: `/tmp/mindwire-project-selection-ui-final.xcresult` (5 passed).
Final chat unit results: `/tmp/mindwire-selection-verified-unit.xcresult` (64 passed).

The final outline catalog passed the import audit for all 129 assets. All six
physical-device icon and service-sheet regression tests passed in
`/tmp/mindwire-outline-icons-device-final.xcresult`, including the native tab/menu
image sizes, destructive role, dynamic type and first-open sheet stability.

The current More icon passed the catalog import audit (129 assets). The final
physical-device run passed all 55 checks: 53 chat lifecycle tests and both
Projects options/activity UI tests (`/tmp/mindwire-more-stop-final-device.xcresult`).
The options tests cover the same button in light/dark list and grid views,
opening the native sheet, starting a project, and returning to folder actions.

The initial Stop regression fixture reused a cancelled run's ID for its next
turn. The fixture now assigns a fresh identity and replay buffer, as the daemon
does. Native question snapshots also write to the app's temporary directory on
the physical phone. All nine targeted rechecks passed before the final full
lifecycle run (`/tmp/mindwire-stop-questions-device-recheck.xcresult`). They cover
Codex/Claude native and asynchronous questions disappearing immediately on Stop,
staying dismissed after reopening, and ignoring a late answer failure. A rejected
Stop keeps the question answerable, and the next run can show a new question.

The corresponding daemon change is merged in Mindwire PR #35. Its Go race,
SDK, Docker end-to-end, web and console checks passed. It closes unanswered
questions with the cancelled run, rejects stale replies, and repairs older
cancelled state while retaining readable history and normal completed questions.
Mindwire 0.1.47 is published, with a green release workflow. A clean public npm
install verified the CLI version, SDK and checksum-verified daemon, cancelled
question repair through the real HTTP API, rejection of a stale answer, and
preservation of a normally completed question. Runtime and console images have
matching version/latest digests for both Linux architectures.

The updated app was launched normally on the iPhone after the fixture tests.

The custom-icons-only follow-up passed the existing light/dark list/grid UI test
on the physical iPhone (`/tmp/mindwire-project-custom-icons-only-device.xcresult`).
The four project screenshots above were refreshed and visually reviewed. The
shared card applies the same behavior in the Projects tab, folders and workspace
project lists, using cached artwork without adding requests.
