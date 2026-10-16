import SwiftUI
import UniformTypeIdentifiers

private struct OpenFilePathKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private extension EnvironmentValues {
    var openFilePath: String? {
        get { self[OpenFilePathKey.self] }
        set { self[OpenFilePathKey.self] = newValue }
    }
}

/// Self-loading file browser for any `(workspace, basePath)`.
/// - **browse** (default): native push navigation (each folder is a pushed screen with a back
///   button + skeleton-on-push), native `.searchable` wired to the backend search handler, native
///   multi-select with batch actions, a ⋯ menu and per-item actions. The workspace Files module.
/// - **selectFolder**: navigate into dirs, make a folder, "Select this folder" → `onSelect`.
struct FilesSheet: View {
    let workspace: WorkspaceService
    var basePath: String = "/"
    var title: String = t("workspace.files.title")
    var selectFolder: Bool = false
    /// A read-only, filtered file picker, reusing this browser's navigation and native search.
    var selectFileExtensions: Set<String>? = nil
    /// Open already navigated to this folder (with a real back-stack up to `basePath`), so a global
    /// selection reopens where you left off and can still navigate UP to parents. nil = start at root.
    var startPath: String? = nil
    /// The project this browser belongs to, if any — enables the editor's "Send to Agent" (a chat
    /// needs a project). nil when browsing a bare workspace.
    var projectId: String? = nil
    var onSelect: ((String) -> Void)? = nil
    /// A deep link can open a file without rebuilding the folder browser.
    var initialFile: String? = nil
    var initialLine: Int? = nil
    /// Chat previews can close from the editor or a nested folder in one tap.
    var allowsQuickClose = false

    @Environment(\.dismiss) private var dismiss   // the SHEET's dismiss (not a nav-stack pop)
    @State private var root: String?
    @State private var clip: FileClip?
    /// Type-erased so the stack can push folder paths (`String`) AND file-editor routes.
    @State private var navPath = NavigationPath()
    @State private var editorPath = NavigationPath()
    @State private var selectedFile: FileEditorRoute?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var fileDirty = false
    @State private var pendingFile: FileEditorRoute?
    @State private var pendingClose = false
    @State private var confirmingDiscard = false
    /// VS Code-style git status coloring for files + folders (empty when not a repo).
    @State private var gitDeco = GitDecorations()
    /// Bumped after any mutation so every level in the stack reloads (keeps the source of a move
    /// in sync, not just the destination).
    @State private var refresh = 0
    /// Persisted across opens. Tree is a single-screen view (no push), so it ignores `navPath`.
    @AppStorage("mindwire.files.layout") private var layout: FilesLayout = .tree

    /// Folder selection ALWAYS uses the drill-in list: tap a folder to push into it, then
    /// "Select this folder" picks that level. The tree (expand-in-place, no push) can't express a
    /// navigated selection — it would always pick the root — so we override the saved layout here.
    private var folderLayout: Binding<FilesLayout> {
        selectFolder || selectFileExtensions != nil ? .constant(.list) : $layout
    }

    var body: some View {
        Group {
            if selectFolder || selectFileExtensions != nil {
                browser
            } else {
                NavigationSplitView(preferredCompactColumn: $preferredColumn) {
                    browser
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
                } detail: {
                    NavigationStack(path: $editorPath) {
                        Group {
                            if let selectedFile {
                                FileEditorScreen(workspace: workspace, path: selectedFile.path,
                                                 repoRoot: selectedFile.repoRoot, projectId: projectId,
                                                 onOpenChat: { id, draft in
                                                     editorPath.append(ChatDraftRoute(chatId: id, draft: draft))
                                                 }, onDirtyChange: { fileDirty = $0 }, initialLine: selectedFile.line)
                                    .id(selectedFile.path)
                                    .toolbar { quickCloseToolbar }
                            } else {
                                ContentUnavailableView("Choose a file", icon: .fileCode,
                                                       description: Text("Browse your project alongside the editor."))
                                    .navigationTitle(title)
                                    .navigationBarTitleDisplayMode(.inline)
                            }
                        }
                        .navigationDestination(for: ChatDraftRoute.self) { route in
                            ChatScreen(chatId: route.chatId, draft: route.draft)
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .environment(\.openFilePath, selectedFile?.path)
        .workspaceToolPresentation()
        .interactiveDismissDisabled(fileDirty)
        .alert("Discard unsaved changes?", isPresented: $confirmingDiscard) {
            Button("Discard Changes", role: .destructive) {
                fileDirty = false
                if pendingClose { dismiss() }
                else if let pendingFile { selectFile(pendingFile) }
                pendingFile = nil
                pendingClose = false
            }
            Button(t("common.cancel"), role: .cancel) { pendingFile = nil; pendingClose = false }
        } message: { Text("Your edits haven't been saved to this workspace.") }
        .task {
            if root == nil {
                let r = await resolveBase(workspace, basePath)
                root = r
                if let startPath {
                    let start = await resolveBase(workspace, startPath)
                    for folder in fAncestorChain(from: r, to: start) { navPath.append(folder) }
                }
                if !selectFolder && selectFileExtensions == nil {
                    if let initialFile { selectFile(FileEditorRoute(path: initialFile, repoRoot: r, line: initialLine)) }
                    await gitDeco.load(workspace: workspace, root: r)
                }
            }
        }
        .task(id: refresh) {
            if let root, !selectFolder, selectFileExtensions == nil, refresh > 0 { await gitDeco.load(workspace: workspace, root: root) }
        }
    }

    private var browser: some View {
        NavigationStack(path: $navPath) {
            Group {
                if let root {
                    FolderView(workspace: workspace, path: root, isRoot: true, title: title,
                               selectFolder: selectFolder, selectFileExtensions: selectFileExtensions,
                               onSelect: { picked in onSelect?(picked); dismiss() }, clip: $clip,
                               refresh: $refresh, layout: folderLayout, gitDeco: gitDeco, onOpen: { navPath.append($0) },
                               onOpenFile: { openFile($0, root: root) }, onClose: close)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationDestination(for: String.self) { childPath in
                FolderView(workspace: workspace, path: childPath, isRoot: false, title: title,
                           selectFolder: selectFolder, selectFileExtensions: selectFileExtensions,
                           onSelect: { picked in onSelect?(picked); dismiss() }, clip: $clip,
                           refresh: $refresh, layout: folderLayout, gitDeco: gitDeco, onOpen: { navPath.append($0) },
                           onOpenFile: { openFile($0, root: root) }, onClose: close)
                    .toolbar { quickCloseToolbar }
            }
        }
    }

    @ToolbarContentBuilder private var quickCloseToolbar: some ToolbarContent {
        if allowsQuickClose {
            AppToolbarItem(placement: .confirmationAction) {
                Button(t("common.done"), action: close).tint(.primary)
                    .accessibilityIdentifier("files.closePreview")
            }
        }
    }

    private func openFile(_ path: String, root: String?) {
        if selectFileExtensions != nil { onSelect?(path); dismiss() }
        else {
            let route = FileEditorRoute(path: path, repoRoot: root)
            if fileDirty && selectedFile?.path != path {
                pendingFile = route
                confirmingDiscard = true
            } else { selectFile(route) }
        }
    }

    private func selectFile(_ route: FileEditorRoute) {
        if selectedFile?.path != route.path { fileDirty = false }
        selectedFile = route
        editorPath = NavigationPath()
        preferredColumn = .detail
    }

    private func close() {
        if fileDirty { pendingClose = true; confirmingDiscard = true }
        else { dismiss() }
    }
}

/// File browser layouts: a row list, an iOS Files-style grid, or a VS Code-style collapsible tree.
enum FilesLayout: String, CaseIterable { case list, grid, tree }

/// Row/text/icon density for the browser — a single scale applied to fonts, icons, and spacing.
/// `.large` keeps the original sizes.
enum FilesDensity: String, CaseIterable {
    case small, medium, large
    var scale: CGFloat { self == .small ? 0.8 : (self == .medium ? 0.9 : 1.0) }
    var label: String { t("files.density.\(rawValue)") }
    var symbol: AppIconName { .type }
}

/// Cut/copy clipboard, shared across folder levels.
struct FileClip { let items: [FileEntry]; let cut: Bool }

/// Nav route for opening a file in the code editor (Hashable so it rides the NavigationStack).
/// `repoRoot` scopes the git diff used for the editor's change tints.
struct FileEditorRoute: Hashable { let path: String; var repoRoot: String? = nil; var line: Int? = nil }

/// Nav route for opening an agent chat in-sheet with a prefilled composer draft ("Send to Agent").

private enum FilePrompt: Identifiable {
    case newFolder, newFile, renameFolder, rename(FileEntry)
    var id: String {
        switch self {
        case .newFolder: return "newFolder"; case .newFile: return "newFile"
        case .renameFolder: return "renameFolder"; case .rename(let e): return "rename:\(e.path)"
        }
    }
}

// MARK: - One folder level (pushed natively per directory)

private struct FolderView: View {
    let workspace: WorkspaceService
    let path: String
    let isRoot: Bool
    let title: String
    let selectFolder: Bool
    var selectFileExtensions: Set<String>? = nil
    let onSelect: ((String) -> Void)?
    @Binding var clip: FileClip?
    @Binding var refresh: Int
    @Binding var layout: FilesLayout
    let gitDeco: GitDecorations
    let onOpen: (String) -> Void
    let onOpenFile: (String) -> Void
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openFilePath) private var openFilePath
    @AppStorage("mindwire.files.density") private var density: FilesDensity = .large
    var treePreferences = FileTreePreferences()
    private var s: CGFloat { density.scale }

    @State private var entries: [FileEntry] = []
    @State private var treeRevision = 0
    @State private var loaded = false
    @State private var query = ""
    @State private var results: [FileEntry] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var editMode: EditMode = .inactive
    @State private var selecting = false                 // unified select mode (all layouts)
    @State private var selection = Set<String>()         // selected ids (= paths)
    @State private var selectedItems: [String: FileEntry] = [:]   // id → entry (survives nesting)
    @State private var prompt: FilePrompt?
    @State private var promptText = ""
    @State private var deleteTargets: [FileEntry] = []
    @State private var busy = false
    @State private var loading = false
    @State private var skeletonPulse = false
    @State private var pending = Set<String>()   // paths with an in-flight op (shown dimmed)
    @State private var showViewOptions = false   // layout + size sheet
    @State private var showTreeSettings = false
    @State private var showUpload = false        // file importer
    @State private var infoTarget: FileEntry?    // Get Info sheet
    @State private var download: WorkspaceFileDownloadRequest?
    @State private var loadError: String?

    private var canManage: Bool { !selectFolder && selectFileExtensions == nil }
    private var editing: Bool { selecting }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var shown: [FileEntry] {
        let files = isSearching ? results : entries
        guard let selectFileExtensions else { return files }
        return files.filter { $0.type == .dir || selectFileExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
    }

    // MARK: Selection (works across list / grid / tree)

    private func enterSelect() {
        selecting = true
        if layout == .list { withAnimation { editMode = .active } }   // native circles in list
    }
    private func exitSelect() {
        withAnimation { selecting = false; editMode = .inactive }
        selection = []; selectedItems = [:]
    }
    private func toggleSelection(_ e: FileEntry) {
        if selection.contains(e.id) { selection.remove(e.id); selectedItems[e.id] = nil }
        else { selection.insert(e.id); selectedItems[e.id] = e }
    }
    /// Keep `selectedItems` in sync when the native List selection mutates `selection` directly.
    private func reconcileSelection() {
        for id in selectedItems.keys where !selection.contains(id) { selectedItems[id] = nil }
        for e in shown where selection.contains(e.id) && selectedItems[e.id] == nil { selectedItems[e.id] = e }
    }

    var body: some View {
        layoutContent
        .refreshable { treeRevision &+= 1; await load() }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { skeletonPulse = true }
        }
        .searchable(text: $query, prompt: t("files.search"))
        .searchToolbarBehavior(!canManage ? .minimize : .automatic)
        .searchPresentationToolbarBehavior(!canManage ? .avoidHidingContent : .automatic)
        .onChange(of: layout) { _, _ in exitSelect() }
        .onChange(of: selection) { _, _ in reconcileSelection() }
        .environment(\.editMode, $editMode)
        .navigationTitle(isRoot ? title : folderName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $showViewOptions) { ViewOptionsSheet(layout: $layout) }
        .sheet(isPresented: $showTreeSettings) { FileTreeSettingsSheet() }
        .sheet(item: $infoTarget) { entry in FileInfoSheet(workspace: workspace, entry: entry) }
        .workspaceFileDownload($download, workspace: workspace)
        .fileImporter(isPresented: $showUpload, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await upload(result) }
        }
        .safeAreaInset(edge: .bottom) {
            if canManage, let clip {
                clipboardBanner(clip)
            }
        }
        .task(id: refresh) { await load() }   // initial load + reload whenever any level mutates
        .onChange(of: query) { _, q in scheduleSearch(q) }
        // ONE native alert drives both create/rename (text input) and delete (destructive confirm).
        // Two separate `.alert`s on one view conflict (the second is silently swallowed), so they
        // share a single modifier and switch content on whichever is active.
        .alert(dialogTitle, isPresented: dialogPresented) {
            if prompt != nil {
                TextField(promptPlaceholder, text: $promptText).textInputAutocapitalization(.never).autocorrectionDisabled()
                // Capture kind+name SYNCHRONOUSLY: dismissing fires the binding setter (which clears
                // `prompt`) before a `Task` body would read it — reading it async saw nil → no-op.
                Button(promptConfirm) {
                    let kind = prompt
                    let name = promptText.trimmingCharacters(in: .whitespaces)
                    prompt = nil; promptText = ""
                    Task { await performPrompt(kind, name) }
                }
                Button(t("common.cancel"), role: .cancel) { promptText = ""; prompt = nil }
            } else {
                Button(t("common.delete"), role: .destructive) {
                    let targets = deleteTargets   // capture before dismissal clears it
                    deleteTargets = []
                    Task { await performDelete(targets) }
                }
                Button(t("common.cancel"), role: .cancel) { deleteTargets = [] }
            }
        } message: {
            if prompt == nil, !deleteTargets.isEmpty { Text(deleteMessage) }
        }
    }

    // MARK: Layouts

    @ViewBuilder
    private var layoutContent: some View {
        switch layout {
        case .list: listBody
        case .grid: gridBody
        case .tree: treeBody
        }
    }

    private var listBody: some View {
        List(selection: $selection) {
            Section {
                if !loaded {
                    ForEach(0..<8, id: \.self) { i in
                        skeletonRow(i)
                            .listRowInsets(EdgeInsets(top: 9 * s, leading: 16, bottom: 9 * s, trailing: 16))
                            .listRowSeparator(.hidden)
                    }
                } else if let loadError, shown.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(loadError).font(.subheadline).foregroundStyle(.secondary)
                        Button(t("common.retry")) { Task { await load() } }.tint(.primary)
                    }
                } else if shown.isEmpty {
                    Text(isSearching ? t("files.noMatches") : t("workspace.files.empty")).foregroundStyle(.secondary)
                } else {
                    ForEach(shown) { row($0) }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 36 * s)
    }

    private var gridBody: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96 * s), spacing: Spacing.md)], spacing: Spacing.lg * s) {
                if !loaded {
                    ForEach(0..<8, id: \.self) { _ in skeletonTile }
                } else if shown.isEmpty {
                    Text(isSearching ? t("files.noMatches") : t("workspace.files.empty"))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, Spacing.xl)
                } else {
                    ForEach(shown) { gridTile($0) }
                }
            }
            .padding(Spacing.lg)
        }
    }

    private func gridTile(_ entry: FileEntry) -> some View {
        Button {
            if selecting { toggleSelection(entry) }
            else if entry.type == .dir { onOpen(entry.path) }
            else { onOpenFile(entry.path) }
        } label: {
            VStack(spacing: Spacing.sm * s) {
                Group {
                    if entry.type == .dir {
                        AppIcon(.folderFilled, size: 40 * s).foregroundStyle(FileIconTheme.folderColor)
                    } else {
                        FileIcon(name: entry.name, size: 42 * s)
                    }
                }
                .frame(height: 44 * s)
                Text(entry.name).font(.system(size: 12 * s)).lineLimit(2).multilineTextAlignment(.center)
                    .foregroundStyle(fileNameColor(entry, gitDeco)).frame(height: 30 * s, alignment: .top)
            }
            .frame(maxWidth: .infinity).padding(.vertical, Spacing.sm * s)
            .background(openFilePath == entry.path && !selecting ? Palette.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if selecting { selectionMark(entry) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("file.entry." + entry.path)
        .accessibilityAddTraits(openFilePath == entry.path && !selecting ? .isSelected : [])
        .opacity(rowOpacity(entry))
        .appContextMenu { if canManage && !selecting { itemActions(entry) } }
    }

    /// Selection checkmark used by grid tiles and tree rows (native circle look).
    private func selectionMark(_ entry: FileEntry) -> some View {
        let on = selection.contains(entry.id)
        return AppIcon(on ? .checkCircleFilled : .circle)
            .font(.title3)
            .foregroundStyle(on ? Palette.accent : Color.secondary)
            .background(Circle().fill(Color(.systemBackground)).padding(2))
    }

    private var skeletonTile: some View {
        VStack(spacing: Spacing.sm * s) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.08)).frame(width: 42 * s, height: 44 * s)
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)).frame(height: 10 * s).padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity).opacity(skeletonPulse ? 1 : 0.45).padding(.vertical, Spacing.sm * s)
    }

    private var treeBody: some View {
        List {
            if !loaded {
                ForEach(0..<8, id: \.self) { i in
                    skeletonRow(i)
                        .listRowInsets(EdgeInsets(top: treePreferences.rowPadding * s, leading: 14,
                                                 bottom: treePreferences.rowPadding * s, trailing: 14))
                        .listRowSeparator(.hidden)
                }
            } else if shown.isEmpty {
                Text(isSearching ? t("files.noMatches") : t("workspace.files.empty")).foregroundStyle(.secondary)
            } else {
                FileTree(entries: shown, source: .workspace(workspace, revision: refresh &+ treeRevision), selecting: selecting,
                         appearance: { entry in
                    FileTreeAppearance(foreground: fileNameColor(entry, gitDeco), opacity: rowOpacity(entry),
                                       selected: openFilePath == entry.path, checked: selection.contains(entry.id),
                                       identifier: "file.entry." + entry.path)
                }, onOpen: { entry in
                    if selecting { toggleSelection(entry) }
                    else { onOpenFile(entry.path) }
                }, accessory: { entry in
                    statusBadge(entry, gitDeco)
                }, decoration: { entry, expanded in
                    ExplorerTreeActions(workspace: workspace, entry: entry, clip: $clip, refresh: $refresh,
                                        expanded: expanded, selecting: selecting,
                                        onRename: { e in promptText = e.name; prompt = .rename(e) },
                                        onDelete: { e in deleteTargets = [e] }, onInfo: { infoTarget = $0 },
                                        onDownload: { download = .init(path: $0.path) })
                })
            }
        }
        .modifier(FileTreeListStyle())
    }

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        Group {
            if editing && canManage {
                fileLabel(entry)                       // plain → native multi-select handles the tap
            } else if entry.type == .dir {
                Button { onOpen(entry.path) } label: {  // programmatic push (reliable with List selection)
                    HStack(spacing: Spacing.sm) {
                        fileLabel(entry)
                        Spacer(minLength: Spacing.sm)
                        statusBadge(entry, gitDeco)
                        AppIcon(Icon.chevron).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
            } else {
                Button { onOpenFile(entry.path) } label: {  // open in the editor
                    HStack(spacing: Spacing.sm) {
                        fileLabel(entry)
                        Spacer(minLength: Spacing.sm)
                        statusBadge(entry, gitDeco)
                    }
                }
                .tint(.primary)
            }
        }
        .tag(entry.id)
        .accessibilityIdentifier("file.entry." + entry.path)
        .accessibilityAddTraits(openFilePath == entry.path && !editing ? .isSelected : [])
        .listRowBackground(openFilePath == entry.path && !editing ? Palette.accent.opacity(0.12) : Color(.systemBackground))
        .opacity(rowOpacity(entry))   // pending op → dim; cut → dim (Finder-style)
        .listRowInsets(EdgeInsets(top: 9 * s, leading: 16, bottom: 9 * s, trailing: 16))  // compact, density-scaled
        .listRowSeparator(.hidden)   // no dividers — clean VS Code-style spacing
        .appContextMenu { if canManage { itemActions(entry) } }
        .swipeActions(edge: .trailing) {
            if canManage {
                Button(role: .destructive) { deleteTargets = [entry] } label: { Label(t("common.delete"), icon: Icon.trash) }
            }
        }
    }

    /// Rounded shimmer placeholder row shown while a folder loads.
    // Placeholder row that matches a real row's size (density-scaled). Row height + separators come
    // from the same `.listRowInsets` / `.listRowSeparator(.hidden)` applied at the call site.
    private func skeletonRow(_ index: Int) -> some View {
        let widths: [CGFloat] = [150, 210, 120, 185, 95, 165, 135]
        return HStack(spacing: Spacing.sm + 2) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08)).frame(width: 22 * s, height: 22 * s)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.08)).frame(width: widths[index % widths.count] * s, height: 11 * s)
            Spacer()
        }
        .opacity(skeletonPulse ? 1 : 0.45)
    }

    private func isCut(_ entry: FileEntry) -> Bool {
        guard let clip, clip.cut else { return false }
        return clip.items.contains { $0.path == entry.path }
    }

    private func rowOpacity(_ entry: FileEntry) -> Double {
        if pending.contains(entry.path) { return 0.5 }   // in-flight op
        if isCut(entry) { return 0.4 }                   // cut, awaiting paste
        if entry.isIgnored { return 0.4 }                // gitignored — VS Code-style dim
        return 1
    }

    // Optimistic UI: reflect the change immediately (dimmed), then `load()` reconciles with the server.
    private func optimisticAdd(_ name: String, _ p: String, _ type: FileEntry.Kind) {
        let entry = FileEntry(name: name, path: p, type: type, size: nil, modifiedAt: nil)
        withAnimation { entries = fSort(entries.filter { $0.path != p } + [entry]); pending.insert(p) }
    }
    private func optimisticRename(_ e: FileEntry, _ name: String, _ newPath: String) {
        withAnimation {
            entries = fSort(entries.map {
                $0.path == e.path ? FileEntry(name: name, path: newPath, type: $0.type, size: $0.size, modifiedAt: $0.modifiedAt) : $0
            })
            pending.insert(newPath)
        }
    }

    private func fileLabel(_ entry: FileEntry) -> some View {
        // Icon (folder → Monokai-orange folder; file → type glyph) in a fixed column so the
        // Keep the file glyph column aligned with the tightly cropped folder artwork.
        HStack(spacing: Spacing.sm + 2) {
            Group {
                if entry.type == .dir {
                    AppIcon(.folderFilled, size: 22 * s).foregroundStyle(FileIconTheme.folderColor)
                } else {
                    FileIcon(name: entry.name, size: 22 * s)
                }
            }
            .frame(width: 26 * s, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 17 * s)).lineLimit(1)
                    .foregroundStyle(fileNameColor(entry, gitDeco))
                if isSearching {
                    Text(entry.path).font(.system(size: 11 * s)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func itemActions(_ entry: FileEntry) -> some View {
        Button { infoTarget = entry } label: { Label(t("files.info"), icon: .info) }
        if entry.type == .file {
            Button { download = .init(path: entry.path) } label: { Label(t("files.download"), icon: .download) }
                .accessibilityIdentifier("files.download")
        }
        Button { promptText = entry.name; prompt = .rename(entry) } label: { Label(t("common.rename"), icon: Icon.edit) }
        Button { setClip([entry], cut: false) } label: { Label(t("files.copy"), icon: .copy) }
        Button { setClip([entry], cut: true) } label: { Label(t("files.cut"), icon: .scissors) }
        Divider()
        DestructiveButton(t("common.delete"), icon: Icon.trash) { deleteTargets = [entry] }
    }

    /// Upload picked device files into the current folder (binary-safe via base64 over exec).
    private func upload(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        await runBusy {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let dest = fJoin(path, url.lastPathComponent)
                _ = try? await workspace.exec(workspace.shell.command(workspace.shell.writeFile(dest, base64: data.base64EncodedString())))
            }
        }
        await load(); bump()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selectFileExtensions != nil {
            if isRoot { AppToolbarItem(placement: .topBarLeading) { Button(t("common.cancel")) { dismiss() }.tint(.primary) } }
            if loading || searching { AppToolbarItem(placement: .topBarTrailing) { ProgressView().controlSize(.small) } }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
        } else if selectFolder {
            if isRoot { AppToolbarItem(placement: .topBarLeading) { Button(t("common.cancel")) { dismiss() }.tint(.primary) } }
            AppToolbarItem(placement: .topBarTrailing) {
                Button { startPrompt(.newFolder) } label: { AppIcon(.folderPlus) }.tint(.primary)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                // Each pushed level owns its toolbar, so this always selects the visible folder.
                // The sheet's callback dismisses the entire picker, including its back-stack.
                Button { onSelect?(path) } label: {
                    Text(t("project.selectFolder")).foregroundStyle(Palette.onAccent)
                }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
                    .accessibilityLabel(t("project.selectThisFolder"))
                    .accessibilityValue(path)
                    .accessibilityIdentifier("files.selectFolder")
            }
        } else if editing {
            AppToolbarItem(placement: .topBarLeading) {
                Button(t("common.done")) { exitSelect() }.tint(.primary)
            }
            AppToolbarItem(placement: .topBarTrailing) { selectionMenu }
            AppToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { deleteTargets = selectedEntries } label: { AppIcon(Icon.trash) }
                    .tint(.red).disabled(selection.isEmpty)
            }
        } else {
            if isRoot { AppToolbarItem(placement: .topBarLeading) { Button(t("common.done")) { if let onClose { onClose() } else { dismiss() } }.tint(.primary) } }
            if loading || busy {
                AppToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
            AppToolbarItem(placement: .topBarTrailing) { manageMenu }
        }
    }

    /// The ⋯ menu owns Select + create/upload/paste — keeps the header clean (no standalone buttons).
    private var manageMenu: some View {
        AppMenu {
            Button { enterSelect() } label: { Label(t("files.select"), icon: .checkCircle) }
            Divider()
            Button { startPrompt(.newFolder) } label: { Label(t("project.newFolder"), icon: .folderPlus) }
            Button { startPrompt(.newFile) } label: { Label(t("files.newFile"), icon: .filePlus) }
            Button { showUpload = true } label: { Label(t("files.upload"), icon: .upload) }
            if !isRoot {
                Button { promptText = folderName; prompt = .renameFolder } label: { Label(t("files.renameFolder"), icon: Icon.edit) }
            }
            if clip != nil {
                Divider()
                Button { Task { await paste() } } label: { Label(t("files.paste"), icon: .clipboardPaste) }
            }
            Divider()
            Button { showViewOptions = true } label: { Label(t("files.viewOptions"), icon: .sliders) }
            if layout == .tree {
                Button { showTreeSettings = true } label: { Label(t("files.tree.customize"), icon: .folderTree) }
            }
        } label: { AppIcon(Icon.ellipsis).tint(.primary) }
        .disabled(busy)
        .accessibilityIdentifier("files.actions")
    }

    private var selectionMenu: some View {
        AppMenu {
            if selectedEntries.count == 1 {
                Button { renameSelected() } label: { Label(t("common.rename"), icon: Icon.edit) }
                Divider()
            }
            Button { setClip(selectedEntries, cut: false) } label: { Label(t("files.copy"), icon: .copy) }
            Button { setClip(selectedEntries, cut: true) } label: { Label(t("files.cut"), icon: .scissors) }
        } label: { AppIcon(Icon.ellipsis).tint(.primary) }
        .disabled(selection.isEmpty)
    }

    /// Rename the single selected item (works from any layout). Leaves select mode, then prompts.
    private func renameSelected() {
        guard let e = selectedEntries.first else { return }
        exitSelect()
        promptText = e.name; prompt = .rename(e)
    }

    /// Set the clipboard and leave selection mode so the user can navigate + paste (native flow).
    private func setClip(_ items: [FileEntry], cut: Bool) {
        guard !items.isEmpty else { return }
        clip = FileClip(items: items, cut: cut)
        exitSelect()
    }

    /// Persistent clipboard banner — shows what's copied/cut with Paste + Cancel, at every level.
    private func clipboardBanner(_ clip: FileClip) -> some View {
        HStack(spacing: Spacing.md) {
            AppIcon(clip.cut ? .scissors : .copy).foregroundStyle(Palette.accent)
            Text(t(clip.cut ? "files.clip.cut" : "files.clip.copied", ["count": "\(clip.items.count)"]))
                .font(.subheadline).foregroundStyle(.primary)
            Spacer()
            Button(t("files.paste")) { Task { await paste() } }
                .font(.subheadline.weight(.semibold)).tint(Palette.accent).disabled(busy)
            Button { withAnimation { self.clip = nil } } label: {
                AppIcon(.xCircle).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.md)
        .background(.bar)
    }

    private var selectedEntries: [FileEntry] { Array(selectedItems.values) }

    // MARK: Titles / prompt plumbing

    private var folderName: String { path == "/" || path.isEmpty ? "/" : (path as NSString).lastPathComponent }
    /// One binding for the shared alert (create/rename OR delete); clears both on dismiss.
    private var dialogPresented: Binding<Bool> {
        Binding(get: { prompt != nil || !deleteTargets.isEmpty },
                set: { if !$0 { prompt = nil; deleteTargets = [] } })
    }
    private var dialogTitle: String { prompt != nil ? promptTitle : deleteTitle }
    private var deleteMessage: String { t("files.delete.message") }
    private var deleteTitle: String {
        deleteTargets.count == 1 ? t("files.delete.confirm", ["name": deleteTargets.first?.name ?? ""])
                                 : t("files.delete.confirmMany", ["count": "\(deleteTargets.count)"])
    }
    private var promptTitle: String {
        switch prompt {
        case .newFolder: return t("project.newFolder"); case .newFile: return t("files.newFile")
        case .renameFolder: return t("files.renameFolder"); case .rename: return t("common.rename"); case nil: return ""
        }
    }
    private var promptPlaceholder: String {
        if case .newFile = prompt { return t("files.newFile.placeholder") }
        return t("project.newFolder.placeholder")
    }
    private var promptConfirm: String {
        switch prompt { case .rename, .renameFolder: return t("common.rename"); default: return t("common.create") }
    }
    private func startPrompt(_ p: FilePrompt) { promptText = ""; prompt = p }

    // MARK: Data + ops

    private func load() async {
        loading = true
        do {
            let result = try await workspace.listFiles(path)
            withAnimation { entries = fSort(result) }   // server truth replaces optimistic rows
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        pending = []   // the op that triggered this reload is done either way
        loaded = true
        loading = false
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; searching = false; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            searching = true
            let r = (try? await workspace.searchFiles(trimmed, in: path)) ?? []
            if Task.isCancelled { return }
            withAnimation { results = fSort(r) }
            searching = false
        }
    }

    /// Runs the create/rename op. `kind` + `name` are captured at the tap (see the alert) so the
    /// async body never re-reads `@State` that dismissal already cleared.
    private func performPrompt(_ kind: FilePrompt?, _ name: String) async {
        guard let kind, !name.isEmpty else { return }
        // Same-folder ops reconcile the current view directly (reliable); cross-folder ops bump.
        switch kind {
        case .newFolder:
            let p = fJoin(path, name); optimisticAdd(name, p, .dir)
            await run(workspace.shell.makeDir(p)); await load(); bump()
        case .newFile:
            let p = fJoin(path, name); optimisticAdd(name, p, .file)
            await runBusy { try? await workspace.writeFile(p, content: "") }; await load(); bump()
        case .rename(let e):
            // Normalize to absolute paths: bare names (some runtimes list without a dir prefix)
            // resolve against the current folder; nested-tree items keep their own directory.
            let dir = e.path.contains("/") ? fParent(e.path) : path
            let src = e.path.contains("/") ? e.path : fJoin(path, e.name)
            let dst = fJoin(dir, name)
            guard dst != src else { return }
            optimisticRename(e, name, dst)
            await run(workspace.shell.move(from: src, to: dst)); await load(); bump()
        case .renameFolder:
            await run(workspace.shell.move(from: path, to: fJoin(fParent(path), name))); bump(); dismiss()
        }
    }

    /// Deletes `targets` — captured at the tap (see the dialog) so dismissal can't clear them first.
    private func performDelete(_ targets: [FileEntry]) async {
        guard !targets.isEmpty else { return }
        withAnimation { pending.formUnion(targets.map(\.path)) }   // dim until the delete confirms
        if selecting { exitSelect() }
        await run(workspace.shell.remove(targets.map(\.path)))
        await load(); bump()
    }

    private func paste() async {
        guard let clip else { return }
        let wasCut = clip.cut
        for item in clip.items { optimisticAdd(item.name, fJoin(path, item.name), item.type) }
        for item in clip.items {
            let dst = fJoin(path, item.name)
            await run(wasCut ? workspace.shell.move(from: item.path, to: dst)
                             : workspace.shell.copy(from: item.path, to: dst))
        }
        if wasCut { self.clip = nil }
        await load()   // destination reconciles → pasted items go full opacity
        bump()         // a move emptied the source; also nudges the tree to reload expanded children
    }

    /// Nudge other folder levels to reload (via each `.task(id: refresh)`); the current level
    /// reloads itself directly, so this is only for cross-folder effects.
    private func bump() { refresh &+= 1 }

    private func run(_ command: String) async { await runBusy { _ = try? await workspace.exec(workspace.shell.command(command)) } }
    private func runBusy(_ work: () async -> Void) async { busy = true; await work(); busy = false }
}

// MARK: - Explorer actions for the shared tree

private struct ExplorerTreeActions: ViewModifier {
    let workspace: WorkspaceService
    let entry: FileEntry
    @Binding var clip: FileClip?
    @Binding var refresh: Int
    @Binding var expanded: Bool
    let selecting: Bool
    let onRename: (FileEntry) -> Void
    let onDelete: (FileEntry) -> Void
    let onInfo: (FileEntry) -> Void
    let onDownload: (FileEntry) -> Void

    func body(content: Content) -> some View { content.appContextMenu { if !selecting { menu } } }

    @ViewBuilder private var menu: some View {
        Button { onInfo(entry) } label: { Label(t("files.info"), icon: .info) }
        if entry.type == .file {
            Button { onDownload(entry) } label: { Label(t("files.download"), icon: .download) }
                .accessibilityIdentifier("files.download")
        }
        Button { onRename(entry) } label: { Label(t("common.rename"), icon: Icon.edit) }
        Button { clip = FileClip(items: [entry], cut: false) } label: { Label(t("files.copy"), icon: .copy) }
        Button { clip = FileClip(items: [entry], cut: true) } label: { Label(t("files.cut"), icon: .scissors) }
        if entry.type == .dir, let clip {
            Button { Task { await paste(clip) } } label: { Label(t("files.paste"), icon: .clipboardPaste) }
        }
        Divider()
        DestructiveButton(t("common.delete"), icon: Icon.trash) { onDelete(entry) }
    }

    private func paste(_ clip: FileClip) async {
        for item in clip.items {
            let dst = fJoin(entry.path, item.name)
            _ = try? await workspace.exec(workspace.shell.command(
                clip.cut ? workspace.shell.move(from: item.path, to: dst)
                         : workspace.shell.copy(from: item.path, to: dst)))
        }
        if clip.cut { self.clip = nil }
        refresh &+= 1
        expanded = true
    }
}

// MARK: - File-scope helpers

// `fileTypeIcon(_:)` is shared from DesignSystem/FileGlyph.swift.

/// Name color: git status color when the entry (or, for a folder, its subtree) has changes; else a
/// calm base — the same soft shade for files AND folders.
@MainActor
private func fileNameColor(_ entry: FileEntry, _ deco: GitDecorations) -> Color {
    if let color = deco.color(for: entry.path, isDir: entry.type == .dir) { return color }
    return Color.primary.opacity(0.82)
}

/// Trailing git-status badge (VS Code-style): a changed FILE shows its status letter (M/A/U/D/R/C/T)
/// in full status color; a FOLDER whose subtree changed shows a dimmer, slightly bigger aggregate dot.
@MainActor @ViewBuilder
private func statusBadge(_ entry: FileEntry, _ deco: GitDecorations) -> some View {
    if entry.type == .dir {
        if let color = deco.color(for: entry.path, isDir: true) {
            Circle().fill(color.opacity(0.55)).frame(width: 10, height: 10)
        }
    } else if let badge = deco.fileBadge(for: entry.path) {
        Text(badge.letter)
            .font(.caption.weight(.bold)).monospacedDigit()
            .foregroundStyle(badge.color)
            .frame(minWidth: 12)
    }
}

private func resolveBase(_ workspace: WorkspaceService, _ basePath: String) async -> String {
    guard basePath.hasPrefix("~") else { return basePath }
    let home = try? await workspace.homeDirectory()
    guard let home, !home.isEmpty else { return basePath }
    if basePath == "~" { return home }
    if basePath.hasPrefix("~/") { return home + "/" + String(basePath.dropFirst(2)) }
    return basePath
}

func fSort(_ entries: [FileEntry]) -> [FileEntry] {
    entries.sorted { a, b in
        if a.type != b.type { return a.type == .dir }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
private func fJoin(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? "\(dir)\(name)" : "\(dir)/\(name)" }

/// The chain of intermediate folders from `root` (exclusive) down to `target` (inclusive), so the
/// nav stack can be pre-seeded — e.g. root "/", target "/home/u/p" → ["/home","/home/u","/home/u/p"].
/// Empty if `target` isn't under `root` (or equals it).
private func fAncestorChain(from root: String, to target: String) -> [String] {
    let base = root == "/" ? "" : (root.hasSuffix("/") ? String(root.dropLast()) : root)
    guard target == base || target.hasPrefix(base + "/") else { return [] }
    let rest = String(target.dropFirst(base.count))
    var cur = base
    var chain: [String] = []
    for part in rest.split(separator: "/") {
        cur += "/" + part
        chain.append(cur)
    }
    return chain
}
private func fParent(_ path: String) -> String {
    let p = (path as NSString).deletingLastPathComponent
    return p.isEmpty ? "/" : p
}

// MARK: - View options + Get Info sheets

/// Layout (list/grid/tree) + size (density) — moved off the header into a clean sheet.
struct ViewOptionsSheet: View {
    @Binding var layout: FilesLayout
    @AppStorage("mindwire.files.density") private var density: FilesDensity = .large
    @Environment(\.dismiss) private var dismiss
    @State private var showTreeSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section(t("files.viewMode")) {
                    Picker(t("files.viewMode"), selection: $layout) {
                        Label(t("files.view.list"), icon: .list).tag(FilesLayout.list)
                        Label(t("files.view.grid"), icon: .grid).tag(FilesLayout.grid)
                        Label(t("files.view.tree"), icon: .folderTree).tag(FilesLayout.tree)
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Section(t("files.size")) {
                    Picker(t("files.size"), selection: $density) {
                        ForEach(FilesDensity.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                if layout == .tree {
                    Section {
                        Button { showTreeSettings = true } label: {
                            Label(t("files.tree.customize"), icon: .folderTree)
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle(t("files.viewOptions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { dismiss() }.tint(.primary) } }
        }
        .sheet(isPresented: $showTreeSettings) { FileTreeSettingsSheet() }
        .presentationDetents([.medium, .large])
    }
}

/// "Get Info" — name · kind · size · modified · path. Size/mtime fetched over the shell on appear.
struct FileInfoSheet: View {
    let workspace: WorkspaceService
    let entry: FileEntry
    @Environment(\.dismiss) private var dismiss
    @State private var sizeText = "…"
    @State private var modifiedText: String?

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent(t("info.name"), value: entry.name)
                LabeledContent(t("info.kind"), value: entry.type == .dir ? t("info.folder") : t("info.file"))
                LabeledContent(t("info.size"), value: sizeText)
                if let modifiedText { LabeledContent(t("info.modified"), value: modifiedText) }
                Section(t("info.path")) {
                    Text(entry.path).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .navigationTitle(t("files.info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { dismiss() }.tint(.primary) } }
        }
        .presentationDetents([.medium])
        .task { await loadInfo() }
    }

    private func loadInfo() async {
        let sh = workspace.shell
        if entry.type == .dir {
            let cmd = "echo \"$(ls -1A \(sh.quote(entry.path)) 2>/dev/null | wc -l)\"; du -sh \(sh.quote(entry.path)) 2>/dev/null | cut -f1"
            let out = (try? await workspace.exec(sh.command(cmd)))?.stdout ?? ""
            let parts = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            let count = parts.first ?? "0"
            let size = parts.count > 1 ? parts[1] : "—"
            sizeText = "\(size) · \(count) \(t("info.items"))"
        } else {
            let out = (try? await workspace.exec(sh.command("stat -c '%s|%Y' \(sh.quote(entry.path)) 2>/dev/null")))?.stdout ?? ""
            let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            sizeText = parts.first.flatMap { Int64($0) }
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
            if parts.count > 1, let epoch = Double(parts[1]) {
                let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
                modifiedText = df.string(from: Date(timeIntervalSince1970: epoch))
            }
        }
    }
}
