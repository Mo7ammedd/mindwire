import SwiftUI

/// The explorer's tree renderer. A snapshot supplies Git changes, including deleted paths;
/// a workspace supplies directory children lazily. Both use these same rows and disclosure logic.
enum FileTreeSource {
    case workspace(WorkspaceService, revision: Int)
    case snapshot([String: [FileEntry]])

    var revision: Int {
        if case .workspace(_, let revision) = self { return revision }
        return 0
    }

    var loadsDirectories: Bool {
        if case .workspace = self { return true }
        return false
    }

    func savedChildren(_ entry: FileEntry) -> [FileEntry]? {
        if case .snapshot(let children) = self { return children[entry.path] ?? [] }
        return nil
    }

    func loadChildren(_ entry: FileEntry) async throws -> [FileEntry] {
        switch self {
        case .workspace(let workspace, _): return fSort(try await workspace.listFiles(entry.path))
        case .snapshot(let children): return children[entry.path] ?? []
        }
    }
}

struct FileTreeAppearance {
    var foreground = Color.primary.opacity(0.82)
    var opacity: Double = 1
    var selected = false
    var checked = false
    var progress: String?
    var identifier: String = ""
}

struct FileTree<Accessory: View, Decoration: ViewModifier>: View {
    let entries: [FileEntry]
    let source: FileTreeSource
    var selecting = false
    var expansion: ((FileEntry) -> Binding<Bool>)? = nil
    let appearance: (FileEntry) -> FileTreeAppearance
    let onOpen: (FileEntry) -> Void
    @ViewBuilder let accessory: (FileEntry) -> Accessory
    let decoration: (FileEntry, Binding<Bool>) -> Decoration
    fileprivate var preferences = FileTreePreferences()
    @State private var directories = FileTreeDirectories()

    init(entries: [FileEntry], source: FileTreeSource, selecting: Bool = false,
         expansion: ((FileEntry) -> Binding<Bool>)? = nil,
         appearance: @escaping (FileEntry) -> FileTreeAppearance,
         onOpen: @escaping (FileEntry) -> Void,
         @ViewBuilder accessory: @escaping (FileEntry) -> Accessory,
         decoration: @escaping (FileEntry, Binding<Bool>) -> Decoration) {
        self.entries = entries
        self.source = source
        self.selecting = selecting
        self.expansion = expansion
        self.appearance = appearance
        self.onOpen = onOpen
        self.accessory = accessory
        self.decoration = decoration
    }

    var body: some View {
        if case .snapshot = source {
            // One data item is exactly one List row. A recursive view whose body
            // returns a row plus descendants makes List evaluate every row up
            // front just to discover its identities.
            ForEach(snapshotRows()) { row in
                FileTreeNodeRow(entry: row.entry, branch: row.branch, depth: row.depth, tree: self)
            }
        } else {
            ForEach(entries, id: \.treeID) { entry in
                FileTreeNode(entry: entry, depth: 0, tree: self)
            }
        }
    }

    private func snapshotRows() -> [FileTreeSnapshotRow] {
        var rows: [FileTreeSnapshotRow] = []
        var pending = entries.reversed().map { (entry: $0, depth: 0) }
        var visited: Set<String> = []
        while let (entry, depth) = pending.popLast() {
            guard visited.insert(entry.treeID).inserted else { continue }
            let branch = FileTreeBranch(root: entry, compact: compact, children: source.savedChildren)
            rows.append(FileTreeSnapshotRow(entry: entry, branch: branch, depth: depth))
            if entry.type == .dir, expansionBinding(entry).wrappedValue {
                pending.append(contentsOf: (branch.children ?? []).reversed().map { (entry: $0, depth: depth + 1) })
            }
        }
        return rows
    }

    fileprivate var compact: Bool { preferences.compactFolders && !selecting }

    fileprivate func directory(_ entry: FileEntry) -> FileTreeDirectory { directories.directory(entry.path) }

    fileprivate func children(_ entry: FileEntry) -> [FileEntry]? {
        source.savedChildren(entry) ?? directory(entry).children
    }

    fileprivate func expansionBinding(_ entry: FileEntry) -> Binding<Bool> {
        if let expansion { return expansion(entry) }
        let directory = directory(entry)
        return Binding(get: { directory.expanded }, set: { directory.expanded = $0 })
    }

    /// Opening one folder follows only its single-child chain. Sibling directories stay lazy.
    fileprivate func loadBranch(_ root: FileEntry) async {
        guard source.savedChildren(root) == nil else { return }
        var current = root
        var seen: Set<String> = [root.path]
        do {
            for _ in 0..<FileTreeBranch.maximumComponents {
                try Task.checkCancellation()
                let target = current
                let children = try await directory(target).load(revision: source.revision) {
                    try await source.loadChildren(target)
                }
                try Task.checkCancellation()
                guard compact, children.count == 1, let child = children.first, child.type == .dir,
                      seen.insert(child.path).inserted else { return }
                // Preserve the opened chain when the user switches back to separate folder rows.
                expansionBinding(child).wrappedValue = true
                current = child
            }
        } catch { /* Retain the last listing. Reopening or refreshing can retry a failed read. */ }
    }
}

private struct FileTreeNode<Accessory: View, Decoration: ViewModifier>: View {
    let entry: FileEntry
    let depth: Int
    let tree: FileTree<Accessory, Decoration>

    var body: some View {
        let branch = FileTreeBranch(root: entry, compact: tree.compact, children: tree.children)
        FileTreeNodeRow(entry: entry, branch: branch, depth: depth, tree: tree)
        if entry.type == .dir, tree.expansionBinding(entry).wrappedValue {
            ForEach(branch.children ?? [], id: \.treeID) { child in
                FileTreeNode(entry: child, depth: depth + 1, tree: tree)
            }
        }
    }
}

private struct FileTreeSnapshotRow: Identifiable {
    let entry: FileEntry
    let branch: FileTreeBranch
    let depth: Int
    var id: String { entry.treeID }
}

/// Workspace and prepared Git trees share the exact same row and interactions.
private struct FileTreeNodeRow<Accessory: View, Decoration: ViewModifier>: View {
    let entry: FileEntry
    let branch: FileTreeBranch
    let depth: Int
    let tree: FileTree<Accessory, Decoration>
    @AppStorage("mindwire.files.density") private var density: FilesDensity = .large
    @Environment(\.embeddedWorkspaceTool) private var embedded

    private var s: CGFloat { density.scale * (ApplePlatform.isDesktop ? 0.82 : 1) }
    private var isExpanded: Bool { entry.type == .dir && tree.expansionBinding(entry).wrappedValue }

    private func expansion(_ branch: FileTreeBranch) -> Binding<Bool> {
        Binding(get: { isExpanded }, set: { expanded in
            for component in branch.components { tree.expansionBinding(component).wrappedValue = expanded }
        })
    }

    var body: some View {
        let target = branch.entry
        let appearance = tree.appearance(target)
        let expansion = expansion(branch)
        let loading = tree.source.loadsDirectories
            && branch.components.contains { $0.type == .dir && tree.directory($0).loading }
        // Keep a concrete one-row boundary outside conditional task/action
        // modifiers, so List can count it without evaluating this body's data.
        HStack(spacing: 0) {
            Button {
                if tree.selecting || target.type != .dir { tree.onOpen(target) }
                else {
                    withAnimation { expansion.wrappedValue.toggle() }
                }
            } label: {
                HStack(spacing: 0) {
                    if tree.selecting {
                        AppIcon(appearance.checked ? .checkCircleFilled : .circle)
                            .foregroundStyle(appearance.checked ? Palette.accent : Color.secondary)
                            .frame(width: 28)
                    }
                    FileTreeRow(depth: depth, preferences: tree.preferences, expanded: target.type == .dir ? isExpanded : nil) {
                        if target.type == .dir, ApplePlatform.isDesktop {
                            AppIcon(isExpanded ? .folderFilled : .folder, size: 16 * density.scale)
                                .foregroundStyle(FileIconTheme.folderColor)
                        } else if target.type != .dir {
                            FileIcon(name: target.name, size: 18 * s)
                                .opacity(appearance.progress == nil ? 1 : 0)
                                .overlay {
                                    if let progress = appearance.progress {
                                        ProgressView().controlSize(.mini).accessibilityLabel(progress)
                                    }
                                }
                        }
                    } title: {
                        Text(branch.title).font(.system(size: 16 * s)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(appearance.foreground)
                    } accessory: {
                        if loading { ProgressView().controlSize(.mini) }
                        else { tree.accessory(target) }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(branch.components.count == 1 ? appearance.identifier : tree.appearance(entry).identifier)
            .accessibilityValue(target.type == .dir
                                ? t(isExpanded ? "git.tree.expanded" : "git.tree.collapsed")
                                : appearance.progress ?? "")
            .accessibilityAddTraits(appearance.selected && !tree.selecting ? .isSelected : [])
            .opacity(appearance.opacity)
            .modifier(tree.decoration(target, expansion))
            .modifier(FileTreeBranchLoading(enabled: entry.type == .dir && tree.source.loadsDirectories,
                request: FileTreeLoadRequest(expanded: isExpanded, revision: tree.source.revision, compact: tree.compact)) {
                guard isExpanded else { return }
                await tree.loadBranch(entry)
            })
        }
        .listRowInsets(EdgeInsets(top: tree.preferences.rowPadding * s, leading: 14,
                                 bottom: tree.preferences.rowPadding * s, trailing: 14))
        .listRowSeparator(.hidden)
        .listRowBackground(appearance.selected && !tree.selecting ? Palette.accent.opacity(0.12) : embedded && ApplePlatform.isDesktop ? AssistantDesktopStyle.sidebar : Color(.systemBackground))
    }
}

private struct FileTreeLoadRequest: Equatable { let expanded: Bool; let revision: Int; let compact: Bool }

/// Snapshot rows already have their children. Only real workspace folders need a
/// load task; mounting a file or Git row must not schedule empty main-actor tasks.
private struct FileTreeBranchLoading: ViewModifier {
    let enabled: Bool
    let request: FileTreeLoadRequest
    let load: () async -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.task(id: request, load) }
        else { content }
    }
}

/// Shared List styling keeps the explorer and Source Control at the same compact density.
struct FileTreeListStyle: ViewModifier {
    @AppStorage("mindwire.files.density") private var density: FilesDensity = .large
    func body(content: Content) -> some View {
        content.listStyle(.plain).listRowSpacing(0)
            .environment(\.defaultMinListRowHeight, 24 * density.scale)
    }
}

extension FileEntry {
    /// A deleted file and its replacement directory may share a path in Git status.
    var treeID: String { (type == .dir ? "folder:" : "file:") + path }
}

private struct FileTreeRow<Glyph: View, Title: View, Accessory: View>: View {
    let depth: Int
    let preferences: FileTreePreferences
    var expanded: Bool? = nil
    @ViewBuilder let glyph: () -> Glyph
    @ViewBuilder let title: () -> Title
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(depth) * preferences.indentation)
            Group {
                if let expanded {
                    AppIcon(.chevronRight).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .frame(width: 18)
            glyph().frame(width: 22)
            title().padding(.leading, preferences.labelGap)
            Spacer(minLength: Spacing.sm)
            accessory()
        }
    }
}
