import Runestone
import SwiftUI
import UIKit

/// Opens a file in a native code editor: reads it over the workspace, shows it read-only with syntax
/// highlighting, and lets the user make small edits (Edit → type → Save). Binary / oversized files
/// are shown a notice instead of being opened. Pushed from the file browser.
struct FileEditorScreen: View {
    let workspace: WorkspaceService
    let path: String
    /// Repo/browse root the file was opened under, used to scope `git diff` for the change bars.
    /// nil (or unresolvable) ⇒ no gutter bars, editor works normally.
    var repoRoot: String? = nil
    /// The project this file belongs to — required for "Send to Agent" (a chat needs a project).
    /// nil ⇒ the Send-to-Agent action is hidden (e.g. browsing a bare workspace).
    var projectId: String? = nil
    /// Push the agent chat (in the host's nav stack) with a prefilled composer draft.
    var onOpenChat: ((_ chatId: String, _ draft: String) -> Void)? = nil
    /// When true, a read failure opens a blank editable buffer (the file is created on save) instead
    /// of an error — for a config file that may not exist yet (e.g. `~/.claude/settings.json`).
    var createIfMissing: Bool = false
    /// The file workbench protects unsaved edits when selecting a different file or closing.
    var onDirtyChange: ((Bool) -> Void)? = nil
    /// A Markdown source citation can reveal its line without entering edit/selection mode.
    var initialLine: Int? = nil

    /// Refuse to open files larger than this (read is `cat`-over-exec; this isn't a full IDE).
    private static let maxBytes = 1_000_000

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.stores) private var stores
    @State private var text = ""
    @State private var loadedText = ""
    /// Decoded image when the opened file is a picture (jpg/png/…), shown in a zoomable viewer instead
    /// of the code editor. nil for normal text files.
    @State private var image: UIImage?
    @State private var imageBytes = 0
    /// Git change info driving the editor's gutter bars (empty when not a repo/clean).
    @State private var changes = EditorChanges()
    @State private var loading = true
    @State private var loadedPath: String?
    @State private var loadGeneration = 0
    @State private var unsupported: String?
    @State private var loadError: String?
    @State private var editing = false
    @State private var showSource = false
    @State private var saving = false
    @State private var dirty = false
    @State private var saveError: String?
    @State private var showSettings = false
    @State private var showInfo = false
    @State private var download: WorkspaceFileDownloadRequest?
    @State private var agentPick: SendToAgentPayload?    // presenting the agent picker for this selection
    @State private var selection: String?                // current editor text selection (for Send to Agent)
    @StateObject private var handle = EditorHandle()
    // App-wide editor settings (shared across every open file).
    @AppStorage("mindwire.editor.fontSize") private var fontSize: Double = 13
    @AppStorage("mindwire.editor.wrapLines") private var wrapLines: Bool = false

    private var name: String { (path as NSString).lastPathComponent }
    private var language: TreeSitterLanguage? { CodeLanguage.language(for: name) }
    private var isMarkdown: Bool { Self.isMarkdownFile(name) }

    static func isMarkdownFile(_ name: String) -> Bool {
        let name = (name as NSString).lastPathComponent.lowercased()
        return name == "readme" || ["md", "markdown", "mdown"].contains((name as NSString).pathExtension)
    }

    /// Raster image types `UIImage` can decode — opened as a picture preview, not text. (SVG is left
    /// out on purpose: it's XML, so it opens in the editor with highlighting instead.)
    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "bmp", "heic", "heif", "tiff", "tif", "webp", "ico"]
    private var isImage: Bool { Self.imageExtensions.contains((name as NSString).pathExtension.lowercased()) }

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let unsupported {
                ContentUnavailableView {
                    Label(t("editor.cantOpen"), icon: .fileWarning)
                } description: {
                    Text(unsupported)
                } actions: {
                    downloadButton
                        .buttonStyle(.glass)
                }
            } else if loadError != nil || loadedPath != path {
                ContentUnavailableView {
                    Label(t("editor.loadFailed"), icon: .warning)
                } description: {
                    if let loadError { Text(loadError) }
                } actions: {
                    Button(t("common.retry")) { Task { await load() } }
                    downloadButton
                }
            } else if let image {
                ImageViewer(image: image)
                    .accessibilityIdentifier("file.imagePreview")
                    .background(Color(.secondarySystemBackground))
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if isMarkdown && !editing && !showSource {
                ScrollView {
                    MessageContentView(text: loadedText)
                        .equatable()
                        .padding(Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(ChatLinks(project: projectId.flatMap { stores.projects.get($0) },
                                    workspace: workspace, basePath: (path as NSString).deletingLastPathComponent))
                .accessibilityIdentifier("file.markdownPreview")
            } else {
                GeometryReader { geometry in
                    CodeEditorView(text: $text, language: language,
                                   fontSize: CGFloat(fontSize), isDark: colorScheme == .dark,
                                   wrapLines: wrapLines, isEditable: editing,
                                   changes: changes, contentSafeAreaInsets: geometry.safeAreaInsets,
                                   onSelectionChange: { selection = $0 }, handle: handle, initialLine: initialLine)
                        .ignoresSafeArea(.all, edges: .vertical)
                        .accessibilityIdentifier("file.editor")
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { editorToolbar }
        .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(isPresented: $showSettings) { EditorSettingsView() }
        .sheet(isPresented: $showInfo) { fileInfoSheet }
        .workspaceFileDownload($download, workspace: workspace)
        .sendCodeToAgent($agentPick, projectId: projectId, onOpenChat: onOpenChat)
        .onChange(of: text) { if editing { dirty = (text != loadedText) } }
        .onChange(of: dirty) { _, value in onDirtyChange?(value) }
        .alert(t("editor.saveFailed"), isPresented: saveErrorBinding) {
            Button(t("common.ok"), role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        .task(id: path) { await load() }
    }

    /// A "Send to Agent" quick-action bar shown while text is selected (hidden while editing, and only
    /// when the file belongs to a project — a chat needs one).
    @ViewBuilder
    private var bottomBar: some View {
        if !editing, unsupported == nil, loadError == nil, !loading, image == nil,
           projectId != nil, onOpenChat != nil,
           let code = selection, !code.isEmpty {
            SendCodeToAgentButton {
                agentPick = SendToAgentPayload(path: path, code: code)
            }
            .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
        }
    }

    // MARK: File info

    /// Shows exactly where this file lives (full path) + size/lines, with copy-path — so opening a
    /// config file (or any file) isn't a mystery about its location.
    private var fileInfoSheet: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(t("editor.info.name"), value: name)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("editor.info.path")).font(.caption).foregroundStyle(.secondary)
                        Text(path)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent(t("editor.info.size"),
                                   value: ByteCountFormatter.string(fromByteCount: Int64(image != nil ? imageBytes : loadedText.utf8.count), countStyle: .file))
                    if let image {
                        LabeledContent(t("editor.info.dimensions"),
                                       value: "\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale)) px")
                    } else {
                        LabeledContent(t("editor.info.lines"), value: "\(lineCount)")
                    }
                }
                Section {
                    Button {
                        UIPasteboard.general.string = path
                    } label: {
                        Label(t("editor.info.copyPath"), icon: .copy)
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle(t("editor.info.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("common.done")) { showInfo = false }.tint(.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var lineCount: Int {
        loadedText.isEmpty ? 0 : loadedText.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    // MARK: Toolbar

    private var downloadButton: some View {
        Button { download = .init(path: path) } label: {
            Label(t("files.download"), icon: .download)
        }
        .tint(.primary)
        .accessibilityIdentifier("editor.download")
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if image != nil {
            // Image previews share the same binary-safe download as other file types.
            AppToolbarItem(placement: .topBarTrailing) {
                AppMenu {
                    downloadButton
                    Button { showInfo = true } label: { Label(t("editor.info.title"), icon: .info) }
                } label: { AppIcon(Icon.ellipsis) }
                .tint(.primary)
                .accessibilityLabel("File actions")
            }
        } else if unsupported == nil && loadError == nil && !loading && loadedPath == path {
            // One native ⋯ menu owns Edit + Settings (plain white/primary nav button).
            AppToolbarItem(placement: .topBarTrailing) {
                AppMenu {
                    if editing {
                        Button { Task { await save() } } label: { Label(t("editor.save"), icon: Icon.checkmark) }
                            .disabled(!dirty || saving)
                        Button(role: .cancel) { cancelEdit() } label: { Label(t("editor.stopEditing"), icon: Icon.close) }
                    } else {
                        if isMarkdown {
                            Button {
                                showSource.toggle()
                                selection = nil
                            } label: {
                                Label(t(showSource ? "editor.showPreview" : "editor.showSource"),
                                      icon: showSource ? .eye : .fileCode)
                            }
                            .accessibilityIdentifier("editor.togglePreview")
                        }
                        Button {
                            editing = true
                            // Let SwiftUI apply `isEditable = true` first, then focus the editor.
                            DispatchQueue.main.async { handle.textView?.becomeFirstResponder() }
                        } label: { Label(t("editor.edit"), icon: Icon.edit) }
                        .accessibilityLabel(t("editor.edit"))
                        .accessibilityIdentifier("editor.edit")
                    }
                    Divider()
                    downloadButton
                    Button { showInfo = true } label: { Label(t("editor.info.title"), icon: .info) }
                    Button { showSettings = true } label: { Label(t("editor.settings"), icon: Icon.settings) }
                } label: {
                    AppIcon(Icon.ellipsis)
                }
                .tint(.primary)
                .accessibilityLabel("File actions")
                .accessibilityIdentifier("editor.actions")
            }
        }
        // Code-symbol bar above the keyboard while editing.
        if editing {
            AppToolbarItem(placement: .topBarTrailing) {
                Button(t("editor.save")) { Task { await save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty || saving)
                    .accessibilityIdentifier("editor.save")
            }
            ToolbarItem(placement: .keyboard) { symbolBar }
        }
    }

    /// Exit edit mode, discarding unsaved changes (revert to the last loaded/saved content).
    private func cancelEdit() {
        text = loadedText
        dirty = false
        editing = false
        handle.textView?.resignFirstResponder()
    }


    private var symbolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(Self.symbols, id: \.self) { sym in
                    Button { handle.insert(sym == "⇥" ? "\t" : sym) } label: {
                        Text(sym)
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 28, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .tint(.primary)
                }
                Spacer(minLength: Spacing.sm)
                Button { handle.textView?.resignFirstResponder() } label: {
                    AppIcon(.keyboardHide)
                }.tint(.secondary)
            }
            .padding(.horizontal, Spacing.xs)
        }
    }

    private static let symbols = ["⇥", "{", "}", "(", ")", "[", "]", "<", ">", "=",
                                  ":", ";", ".", ",", "\"", "'", "`", "/", "\\", "|",
                                  "&", "*", "#", "_", "-", "+", "!", "?", "$"]

    // MARK: Load / save

    private func load() async {
        guard loadedPath != path, !Task.isCancelled else { return }
        showSource = initialLine != nil
        selection = nil
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        unsupported = nil
        loadError = nil
        image = nil
        defer { if generation == loadGeneration { loading = false } }
        do {
            if isImage {
                let result = try await readImage()
                try Task.checkCancellation()
                guard generation == loadGeneration else { return }
                image = result.image
                imageBytes = result.bytes
                if image == nil { unsupported = t("editor.binary") }
                loadedPath = path
                return
            }
            let file = try await workspace.readFile(path)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            if file.content.utf8.count > Self.maxBytes {
                unsupported = t("editor.tooLarge")
            } else if file.content.contains("\u{0}") {
                unsupported = t("editor.binary")
            } else {
                text = file.content
                loadedText = file.content
            }
            loadedPath = path
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !error.isRequestCancellation else { return }
            if createIfMissing {
                // Not there yet (e.g. a config file never written) — open a blank editable buffer;
                // saving creates it. A genuine write problem later surfaces on save.
                text = ""; loadedText = ""; editing = true
                loadedPath = path
                APILog.note("editor: \(path) not found — opening as a new file")
            } else {
                loadError = error.localizedDescription
                APILog.note("editor ✗ read \(path): \(error.localizedDescription)")
            }
        }
        loading = false
        if unsupported == nil && loadError == nil { await loadGitDecorations() }
    }

    /// Read an image file's raw bytes (base64 over exec — the same binary-safe transport git blobs
    /// use) and decode it for the preview. Anything that fails to decode falls back to the "no
    /// preview" notice rather than an error.
    private func readImage() async throws -> (image: UIImage?, bytes: Int) {
        let cap = 25_000_000   // ~25 MB source cap; larger images fall back to the notice below.
        let cmd = workspace.shell.readFileBase64(path, capBytes: cap)
        let result = try await workspace.exec(workspace.shell.command(cmd))
        guard result.exitCode == nil || result.exitCode == 0 else {
            throw BackendError.message(result.stderr.isEmpty ? t("editor.loadFailed") : result.stderr)
        }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty,
              let data = Data(base64Encoded: out, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else { return (nil, 0) }
        return (image, data.count)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await workspace.writeFile(path, content: text)
            loadedText = text
            dirty = false
            editing = false
            handle.textView?.resignFirstResponder()
            await loadGitDecorations()   // committed content changed → refresh the change tints
        } catch {
            if !Task.isCancelled && !error.isRequestCancellation { saveError = error.localizedDescription }
        }
    }

    // MARK: Git line tints

    /// Fetch the file's changes vs HEAD (staged + unstaged, plus untracked-as-all-added) and turn them
    /// into a per-line change map. Best-effort: any failure (not a repo, no root, error) clears tints.
    private func loadGitDecorations() async {
        guard let rel = repoRelativePath() else { changes = EditorChanges(); return }
        let git = ExecGitService(workspace: workspace, root: repoRoot)
        switch try? await git.headDiff(path: rel) {
        case .some(.untracked):    changes = Self.allAdded(in: text)              // new file ⇒ every line green
        case .some(.patch(let p)): changes = Self.editorChanges(fromPatch: p)
        default:                   changes = EditorChanges()                      // nil (error) or unchanged
        }
    }

    /// Every line of an untracked file marked added — `git diff` skips untracked files entirely.
    static func allAdded(in text: String) -> EditorChanges {
        guard !text.isEmpty else { return EditorChanges() }
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let count = trimmed.components(separatedBy: "\n").count
        return EditorChanges(lineKinds: Dictionary(uniqueKeysWithValues: (1...count).map { ($0, .added) }))
    }

    /// `path` (absolute) made relative to `repoRoot`, as `git diff -- <pathspec>` expects. nil when the
    /// root is unknown/unusable or the file isn't under it.
    private func repoRelativePath() -> String? {
        guard let root = repoRoot, !root.isEmpty, root != "." else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        if base.isEmpty { return path.hasPrefix("/") ? String(path.dropFirst()) : path }  // root "/"
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return nil
    }

    /// Turn a `git diff HEAD` patch into gutter changes. Per contiguous +/− block: the first
    /// `min(dels, adds)` additions are modifications (blue), extra additions are pure adds (green); a
    /// block with more deletions than additions leaves a red caret anchored at the adjacent line.
    static func editorChanges(fromPatch patch: String) -> EditorChanges {
        let lines = DiffParser.parsePatch(patch)
        var kinds: [Int: GutterKind] = [:]
        var deletions: Set<Int> = []
        var lastNewNo = 1
        var i = 0
        while i < lines.count {
            if let n = lines[i].newNumber { lastNewNo = n }          // track new-file position
            guard lines[i].kind == .addition || lines[i].kind == .deletion else { i += 1; continue }
            var dels = 0
            var addNums: [Int] = []
            while i < lines.count, lines[i].kind == .addition || lines[i].kind == .deletion {
                if lines[i].kind == .deletion { dels += 1 }
                else if let n = lines[i].newNumber { addNums.append(n); lastNewNo = n }
                i += 1
            }
            for (idx, n) in addNums.enumerated() { kinds[n] = idx < dels ? .modified : .added }
            if dels > addNums.count {   // pure deletion(s) → red caret near the removal
                let anchor = addNums.last ?? (i < lines.count ? (lines[i].newNumber ?? lastNewNo) : lastNewNo)
                deletions.insert(max(1, anchor))
            }
        }
        return EditorChanges(lineKinds: kinds, deletionAnchors: deletions)
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }
}

/// App-wide editor settings, presented as a native sheet (room to grow beyond text size + wrap).
/// Reads the same `@AppStorage` keys as the editor, so changes apply live and across every file.
struct EditorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mindwire.editor.fontSize") private var fontSize: Double = 13
    @AppStorage("mindwire.editor.wrapLines") private var wrapLines: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section(t("editor.settings.display")) {
                    Stepper(value: $fontSize, in: 9...28, step: 1) {
                        LabeledContent(t("editor.textSize"), value: "\(Int(fontSize)) pt")
                    }
                    Toggle(t("editor.wrapLines"), isOn: $wrapLines)
                }
            }
            .navigationTitle(t("editor.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { dismiss() }.tint(.primary) }
            }
        }
        .presentationDetents([.medium])
    }
}

/// A pinch-zoom / pan image preview (UIScrollView-backed, like the Photos viewer): opens fit-to-view,
/// double-tap toggles zoom. Used to preview image files in place of a "can't open" notice.
struct ImageViewer: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(iv)
        context.coordinator.imageView = iv

        // Pin the image to fill the viewport at zoom 1 (aspect-fit centres it); the width/height
        // anchors to the frame guide give it a definite size so zoom/scroll content sizing is correct.
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            iv.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            iv.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            iv.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            iv.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = g.location(in: imageView)
                let side = scroll.bounds.size
                let w = side.width / 3, h = side.height / 3
                scroll.zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h),
                            animated: true)
            }
        }
    }
}
