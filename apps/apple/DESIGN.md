# Mindwire — iOS 26 Design Language (v2, from scratch)

This is the single source of truth for the UI. The old React-Native-derived look
(orange chrome, colored status text, flat black screens, custom
Card/Field components) is **retired**. Build every screen from stock iOS 26 SwiftUI so the
app reads as a modern, calm, Liquid-Glass-native app — not a themed port.

## Principles

1. **Native-first.** Every surface is a stock component: `NavigationStack`, `List`/`Form`
   + `Section`, `LabeledContent`, `NavigationLink`, `Toggle`, `Picker`, `TextField`,
   `ContentUnavailableView`, `Menu`, `.searchable`, native toolbars/sheets/alerts. No
   hand-rolled cards, rows, fields, pills, or backgrounds. If iOS has a component, use it.

2. **Centered Oblien mark on tab roots; inline titles on detail.** Each of the 4 tab
   roots shows the monochrome Oblien mark centered in the nav bar via `.principalBrand()`
   (inline title mode — keep `.navigationTitle` set for the back-button label, the mark
   occupies the center). Detail/pushed screens use the entity name as an **inline** title
   (no mark). The mark is always monochrome (`.primary`), never orange.

3. **Calm, monochrome chrome — orange is rare.** The brand orange (`Palette.accent`,
   `#E25D3E`) is the global `.tint`, so genuine controls (toggles, pickers, selected tab,
   in-content links) and the primary CTA carry it. But **chrome is monochrome**:
   - Toolbar / nav-bar buttons: `.tint(.primary)` locally (a clean monochrome glyph).
     Never an orange toolbar button.
   - Status is **never** colored orange/green (see #4).
   - Secondary buttons: `.buttonStyle(.glass)`. Primary CTA only: `.buttonStyle(.glassProminent)`.

4. **Status is quiet — a clean spinner, not a skeleton.** No colored "running / idle /
   ready" text. Use the shared `AgentStatusLabel(status:)`:
   - active (`running`/`provisioning`) → a bare `ProgressView().controlSize(.small)`
     spinner, NO text label (the spinner alone reads as "working" — clean, native),
   - `error` → a small `exclamationmark.triangle.fill` in `.red` (the only status color),
   - everything else (`ready`/`idle`/`awaitingInput`/`archived`) → plain `.secondary` text.
   Same idea for workspace/server state: spinner when busy, `.secondary` otherwise.

5. **System backgrounds — never hard black.** Every screen is a grouped `List`/`Form` so
   dark mode renders the layered grouped hierarchy (elevated cells), not a flat black
   canvas. **No screen sets a raw background** (`Palette.bg`, `Color.black`,
   `.systemBackground` fills, gradients). The single intentional dark surface is the
   terminal canvas. `MainScene` shows the tabs directly — no background ZStack.

6. **Depth by grouping, not borders.** Separation comes from `Section`s, insets, footers,
   and `LabeledContent` — not hairlines, custom fills, or cards. Use `Section(header:)` /
   `Section { } footer: { }` for context. Destructive actions: a `Button(role: .destructive)`
   in its own Section.

7. **Native Dynamic Type for interface text.** Every label uses
   a semantic text style (`.body`/`.headline`/`.subheadline`/`.footnote`/`.caption`) so it
   scales with the user's text-size setting. NEVER `.font(.system(size: N))` (fixed point)
   and NEVER `design: .monospaced` for interface labels — monospaced values (host, latency,
   tokens, ids, paths) read as a "terminal/old" app, which is rejected. Let `LabeledContent`
   render values in its default style; only override with a semantic style when needed. The
   Monospaced text belongs to code, diffs, and terminal content. Code uses the shared editor's
   user-controlled font size; source control labels use semantic system styles.

8. **One assistant identity: Mindwire.** Chats on iOS and Mac use Mindwire's name and
   monochrome mark. Conversation lists have text titles and quiet activity indicators,
   without harness logos. Loading, previews, commands, and voice keep this same identity.
   Provider identities belong in subscription setup and developer configuration. App-owned
   navigation and action icons use the shared `AppIcon` PNG catalog and `AppMenu` wrappers.
   Mac currently uses the shared mobile screens and navigation. Dedicated Mac interface work is
   deferred; do not add a desktop shell or platform-specific chat styling without a new request.

7. **Glass for floating chrome only.** Chat composer, terminal bars, FABs →
   `.glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glass)`. Never put glass behind
   list content (the grouped list already provides the surface).

## Components you may use

- **Lists**: `List { Section(...) { NavigationLink / LabeledContent / Toggle / Picker } }`.
  Tab roots: shared `.principalBrand()` header + `.toolbar` actions (monochrome). Empty →
  `ContentUnavailableView` with an SF Symbol or, on the Projects welcome, a small row of the
  bundled monochrome agent logos. Center the welcome in the available content area. Use one
  primary action; hide the toolbar add button while the Projects welcome offers project creation.
  Workspace issues appear in a compact toolbar indicator, with an exclamation mark and issue
  count. Hide the indicator when there are no issues, including during routine checks. Open details
  in a native sheet with workspace logos and issues first. Projects and the status sheet read the
  shared cache; navigation does not start new checks.
  Project rows restore workspace display metadata from the current session's persisted cache on
  launch. Background revalidation keeps known rows visible; a cold lookup uses a small trailing
  spinner without adding a status line. Cached metadata does not imply live VM/service health.
  Pull-to-refresh and the sheet's refresh action explicitly check again. The app lifecycle owns
  background synchronization.
  Agents, Workspaces, and Projects use the shared `EntityRow` based on the Agents list: a 22-point
  icon column vertically centered beside the complete title and subtitle block, consistent
  icon-to-text spacing, body titles, and secondary subheadlines.
  Project cards show the workspace and cached branch, with shared `GitDiffStats` and compact
  working-agent logos. Full filesystem paths belong in project details, never in cards.
  `ProjectPresentationCache` persists small Git summaries and transparent icon thumbnails;
  row rendering never requests Git status or image bytes. Workspace synchronization, explicit
  refresh, Source Control reads and completed agent runs update/invalidate these snapshots.
  Change Icon opens a native form, previewing images through the shared file picker scoped to the
  project. SVG/PNG/JPEG/GIF selections are relative paths saved by the workspace registry; resetting
  the icon only clears that metadata. Render cached thumbnails in the existing centered icon slot.
  Tab roots place each item in its own native section with compact section spacing. Inline status
  marks and trailing actions keep their existing meaning; context lists can group these same rows.
- **Forms / creation**: `Form`; multi-choice creation = a stepped wizard (one `Form` per
  step + a glass bottom bar), already the pattern in `NewAgentScreen`.
  New Project's Open a folder opens the shared folder picker in the selected workspace.
  Selection registers that folder using its name, then follows the existing first-agent flow.
  Do not insert another workspace or folder-details page; cloning retains its own options.
  Workspace destinations use matching native section cards for Oblien Cloud, Your computer,
  and SSH server. A destination-specific add form does not repeat the type selector; only the
  generic Add connection entry in Settings offers it. Computers & Servers shares EntityRow,
  workspace links, terminal views and private port controls for both connection types.
- **GitHub credentials**: personal access tokens and SSH keys are visible connection methods,
  each with a dedicated native add/edit form. A connection has its own name separate from the
  GitHub account. Details expose Edit, Test Connection, explicit reveal/copy, and removal with
  a native alert. Keep setup instructions and permission links behind an info button. Tests show
  exactly what was checked; past successful checks are secondary, never a promise of current
  repository write access. Show generated public keys for setup; keep saved secrets masked.
  Workspace/project access and the repository picker open the same connection details.
- **Selection (one-of)**: native `Picker(.pickerStyle(.inline))` with `.tag(...)`; never a
  hand-rolled selectable row.
- **Status**: `AgentStatusLabel(status:)` (defined in `DesignSystem/Components/StatusView.swift`).
  Opening a chat uses a compact native connection indicator through the initial history load.
  Keep an already loaded transcript visible during routine reconnects. Installation progress bars,
  elapsed time, and setup steps appear only while the service is actually installing or updating.
  Agent cards show only a small work indicator. Keep download bars, percentages, and setup steps
  inside agent/workspace details so shared service progress is not repeated across the Agents list.
- **Service updates**: the workspace has one compact service row with a trailing check icon.
  Tapping the row opens a native details sheet for versions, release notes, recovery controls,
  and update behavior; never place published-version or explanation footers below the card.
  The sheet uses plain property and action rows, without repeating the workspace's service card
  or section title. Put its check action in the toolbar and the shared automatic-update toggle
  at the bottom, with its all-workspaces scope stated briefly. Show an installed version once
  when it is already the latest release.
  Settings keeps the automatic-update toggle and Update All, with its explanation behind an
  info button. Workspaces has a compact monochrome update menu. All entry points share one
  operation through release discovery, workspace checks, installation, and verification;
  repeated actions join it and controls stay disabled until it finishes. Reopened screens use
  that same live progress. Show measured download percentages and an indeterminate phase bar
  when the backend supplies no byte count. The app lifecycle checks release metadata on launch
  and every five minutes; opening details and navigation only read cache. Manual checks and
  pull-to-refresh bypass the cache. Automatic updates wait for the daemon's idle guard;
  manual Update and Update All authorize a restart under the same exclusive update lock.
  Their details sheet briefly explains that Mindwire terminals close and active agent work
  may be interrupted. Stopped workspaces remain stopped. A failed release check must not
  appear as a successful cached result.
  The update sheet includes every workspace, its installed version and update outcome, plus an
  Update All action. Keep waiting and failed items visible after the batch finishes. A paired
  computer accepts the request into its own durable queue; a manual update promotes an
  existing automatic request without repeating the download. Rechecks quietly observe the
  same request without re-entering agent preparation. Checking and automatic waiting never
  show installation progress or replace a ready agent page. Show automatic terminal blockers
  with a Mindwire terminals action and retain detailed errors. These are app-created sessions,
  separate from the paired control connection and the computer's Terminal app. The terminal
  menu can close a single session with native confirmation.
- **Agent questions and approvals**: pin one compact request control above the chat composer.
  Tapping opens a native answer sheet shared by all harnesses. Keep unsent choices and feedback
  when the sheet closes or a question moves into history. Transcript prompts stay collapsed;
  acknowledged requests leave the composer only after the daemon accepts the response.
- **Chat tools**: the composer's controls icon opens a compact native sheet with the saved model,
  reasoning effort, and the current project's Source Control, Files, and Terminal. Reuse the
  project tool destinations and daemon-driven model settings; keep the conversation and draft in
  place beneath them. Show model loading only while a request is active, and keep failed settings
  retryable. The top-left Add image action uses the native photo picker. Show removable thumbnails
  above the composer, restore them after failed sends, and retain images in history. Reasoning uses
  plain secondary text in this sheet; keep the brain icon in transcript reasoning rows only.
  Do not expose placeholder attachment or legacy preview actions.
- **Chat scrolling**: recycle individual response parts in a native self-sizing transcript, including
  the active run. Keep completed markdown/tool views unchanged while another part streams. Never
  animate height on each text delta. Restore the latest measured row without replaying history;
  pagination keeps stable message anchors and starts only when the reader scrolls up. Preserve the
  reader's position while they inspect older output, including when more history arrives.
  Use iOS 26 soft scroll-edge effects under the navigation bar and a native `safeAreaBar` composer.
  The transcript extends behind the bars; SwiftUI's safe-area insets keep the newest row above the
  composer and keyboard. Individual hosted cells ignore safe areas already handled by the table.
  Do not add solid bar backgrounds or hand-drawn gradients to the chat.
  Group consecutive shell calls in one compact native disclosure, shared by every harness and
  by history/previews. Opening a group reveals individually recycled command rows; each command's
  output stays closed until selected. Keep message and part anchors stable as a group grows, and
  retain the reader's position when opening it. Narrative/tool boundaries have more space than
  adjacent tool rows. File paths and command summaries share secondary subheadline typography;
  file edits reuse `GitDiffStats` and the editor's Monokai diff palette, hiding zero counts.
  Completed thinking uses a quiet Reasoning disclosure with duration. Put available token metadata
  inside it; when reasoning text is withheld, keep the token count inline. Use a native activity
  indicator only while the reasoning part is active, without pulsing the text or replaying history.
- **Source Control**: put the changed files first, with a quiet repository/branch summary and a
  native Files/Review picker. The compact branch row opens a searchable native branch sheet with
  local and remote branches. Local rows have a visible menu for Switch, Rename and Delete; hold
  and swipe reuse these actions. Create/Rename share a native form. Deletion uses a native alert,
  with a second explicit confirmation for unmerged work. Current/other-worktree branches remain
  protected by Git; version 5 operations retain the selected branch tip across retries.
  Keep the branch selector on one compact line;
  its trailing history control opens paged commits for the current branch. History pins the commit
  tip during pagination and refreshes explicitly. Commit details reuse the same compact file rows
  and diff editor, preserving selection-to-agent while hiding worktree mutation controls.
  The commit actions menu offers Restore This Version with a native confirmation. Restoration
  requires a clean working tree and the daemon's guarded operation, preserves commit history,
  and returns to the staged changes for review; it never commits automatically.
  Push, Pull, and Fetch live in a compact native Sync Repository sheet opened from the toolbar.
  Show the destination and concise action descriptions there, share progress with the main screen,
  and keep detailed command output collapsed behind a readable completion message.
  Branch changes use the daemon's durable Git
  operations and preserve uncommitted work; older services explain that an update is required.
  Reuse file icons, readable filename/directory rows, and diff counts.
  Keep file rows compact, with one line each for filename and location at standard text sizes.
  Every row has a visible actions menu; swipe and hold are additional ways to reach the same actions.
  Staged changes can collapse from their existing section header in both Files and Review, keeping
  the count and Unstage All available. Search temporarily reveals matching rows without resetting
  the disclosure. Use the folder picker's native minimized bottom-toolbar search, expanding on focus
  beside Commit; keep the staged count visible while search is inactive.
  Keep the commit message in a native sheet with the same compact staged-file rows, navigation,
  actions menu, Unstage, and Unstage All as the main view. A missing Git author opens a native
  name/email form and preserves the message and staged files. Save Author is independent of
  committing, with native choices for This repository, This workspace, and All workspaces.
  More specific author settings take precedence. The shared default is delivered to connected
  workspaces by the app lifecycle; unavailable workspaces remain visibly pending until acknowledged.
  Repository actions expose the same form even when there are no changes to commit.
  Normal Git empty states share compact, centered title/description typography through
  `GitEmptyState`, without decorative icons or cards. History remains a small text action beside
  the branch selector in both clean and changed repositories. The empty state has no standalone
  history button or empty file-search field; a fresh branch clearly says No commits yet.
  Review previews are bounded and load as rows appear;
  reserve their final viewport before loading, cache excerpts per file and side, and keep them
  visible during refresh. Use eager layout for the short excerpt inside each recycled list row.
  full diffs use the native code editor with changed sections, full-file context, and change navigation.
  Red/green is reserved for diff additions/deletions, not general status. Stage and Unstage reflect
  the side being reviewed; failed operations keep the view open. Discard always uses a native alert.
  Keep Discard and Stage in one equal-width horizontal row from the first presentation, using
  normal primary text on glass for Discard. Put previous/next navigation in the compact file header.
  Open diffs and files scroll beneath native `safeAreaBar` controls with iOS 26 soft edge effects,
  including the selection's Send to Agent footer. Keep gutter decorations beneath the native effect;
  content insets keep the first and last lines clear of the bars. Do not add a solid bar background.
  Use Monokai Pro green/pink-red for diff counts and markers, matching the bundled file icons,
  with deeper variants for light-mode readability. Added and removed lines have solid color rails
  and explicit `+`/`−` markers; do not rely on the background color alone to distinguish changes.
  Line backgrounds use transparent RGB colors at 12% opacity in dark mode and 10% in light mode
  over the native surface. Match the marker hues, with deeper RGB where needed for code contrast.
  Diff gutter markers follow native line geometry through wrapping, scrolling, and font changes;
  draw only the visible lines and keep them beneath the native scroll-edge effects.
  When code scrolls horizontally beneath the pinned gutter, back numbers and markers with an opaque
  fill matching the editor's page or sheet background, ending exactly at the gutter edge. Keep the
  backing below the gutter and the native top/bottom
  edge effects; it never intercepts selection or changes the code's syntax/highlight colors.
  Apply transparency only to the background; preserve the code's normal text and syntax colors.
  Share these colors between open files and previews, without multiplying opacity on the row.
  The current change uses a quiet 3% focus overlay. Code must retain at least 4.5:1 contrast over
  the composited background, including focus, on page and elevated sheet surfaces.
  Discard menu titles and symbols are both system red; the final confirmation remains destructive.
  Previous/next change navigation highlights the active change without selecting its code.
  Selecting code exposes the shared
  Send to Agent flow used by Files: pick a workspace agent, then add a comment in the chat draft.
  Diff selections retain addition/deletion markers when handed to the chat.
- **Mobile modes**: fresh installs choose General or Developer; upgrades keep Developer. Settings
  can switch at any time. General opens the shared chat directly with a flat searchable history.
  Developer owns the existing four tabs. Keep one chat, composer, draft store, history component,
  pairing flow, authentication flow and cloud provisioner. General hides coding configuration,
  terminal and Git shortcuts while retaining attachments, voice, files and downloads. Its setup
  prepares `~/.mindwire-workspace` through the authoritative workspace project registry, and only
  persists IDs for the default profile/project. Existing chats never change computers when the
  default changes. Restore the General conversation per window alongside Developer navigation.
  Mac stays on the shared Developer shell until its interface work is explicitly resumed.
- **File downloads**: files expose Download in every browser layout's context menu and the viewer's
  actions. Unsupported and failed previews offer Download directly. Use the same on-demand transfer
  with native progress, cancel/retry, and Save to Files for all entry points. Preserve original bytes
  and filenames; preview limits never apply to downloads. Cancelled or failed transfers remove their
  partial temporary files. Browsing never starts a transfer.
- **Buttons**: `.glass` (secondary), `.glassProminent` (one primary CTA per screen).
- **Confirmations**: centered native `.alert` with explicit Cancel and a named action
  (Sign out, Delete, Stop, etc.). Destructive actions use `.destructive` and system red,
  including their icons. Use `DestructiveButton` for labeled rows and menu items so symbols
  cannot inherit the orange accent. Swipe actions retain native white labels on red fills.
  Do not use bottom action sheets (`.confirmationDialog` or
  `UIAlertController.Style.actionSheet`) anywhere. Use native `Menu` for action choices
  such as selecting a project or agent; sheets remain for forms and full screens.
- **Brand**: `AppLogo` (orange Oblien mark) — Settings about only.
- **Agent icons**: render the real bundled agent logo (`AgentLogo`) at a consistent size as
  the row leading icon. No extra tint, no colored container.
  The Agents tab lists each agent once with its running status on that row. Running conversations
  belong in project chats and chat history, not as extra agent-like rows on the Agents tab.

## Color reference (`Palette`, all system-backed)

`accent` = Oblien orange (global tint, used sparingly). `text`/`textDim`/`textFaint` =
`.primary`/`.secondary`/`.tertiaryLabel`. Backgrounds = system grouped (never set manually).
`danger` = system red (destructive + error only). Avoid `success`/`warning` as status text.

## Verification checklist (every screen)

- [ ] Root is a grouped `List`/`Form`; no manual background; no `Palette.bg`/`Color.black`.
- [ ] Tab root uses `.principalBrand()` and keeps `.navigationTitle` for navigation and accessibility.
- [ ] Toolbar buttons are monochrome (`.tint(.primary)`), not orange.
- [ ] Status via `AgentStatusLabel` — no `Palette.statusTint` colored text in screens.
- [ ] Selection via native `Picker`; rows via `NavigationLink`/`LabeledContent`.
- [ ] Zero references to deleted components; all tab roots reuse the shared brand header.
- [ ] One `.glassProminent` CTA max; secondary actions `.glass`.
