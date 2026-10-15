import SwiftUI

enum GitFileLayout: String, CaseIterable {
    case list, tree
    var title: String { t("files.view.\(rawValue)") }
    var icon: AppIconName { self == .tree ? .folderTree : .list }
}

/// Git supplies entries, trailing counts and actions to the explorer's own tree renderer.
struct GitFileTreeRows: View {
    let model: GitModel
    let files: [GitFileChange]
    let staged: Bool
    let scope: String
    let review: Bool
    @Binding var collapsed: Set<String>
    let selected: GitDiffRoute?
    let onOpen: (GitFileChange) -> Void
    let onDiscard: (GitFileChange) -> Void
    var breadcrumb: GitScrollBreadcrumb? = nil
    @AppStorage("mindwire.files.density") private var density: FilesDensity = .large
    @State private var cache = GitFileTreeCache()

    var body: some View {
#if DEBUG
        let _ = breadcrumb?.recordTreeBody()
#endif
        let content = cache.content(files: files) {
#if DEBUG
            breadcrumb?.recordTreeBuild()
#endif
        }
        let snapshot = content.snapshot
        let changes = content.changes
        FileTree(entries: snapshot.roots, source: .snapshot(snapshot.children), expansion: { entry in
            Binding(get: { !collapsed.contains(entry.path) }, set: { expanded in
                if expanded { collapsed.remove(entry.path) }
                else { collapsed.insert(entry.path) }
            })
        }, appearance: { entry in
#if DEBUG
            breadcrumb?.recordRowBody()
#endif
            return FileTreeAppearance(selected: entry.type != .dir && selected?.change.path == entry.path && selected?.staged == staged,
                               progress: entry.type == .dir ? nil : model.fileAction(path: entry.path, staged: staged)?.title,
                               identifier: entry.type == .dir ? "git.folder.\(scope).\(entry.path)"
                                   : "git.file.\(staged ? "staged" : "working").\(entry.path)")
        }, onOpen: { entry in
            if let change = changes[entry.path] { onOpen(change) }
        }, accessory: { entry in
            if entry.type == .dir {
                Text((snapshot.counts[entry.path] ?? 0).formatted())
                    .font(.system(size: 12 * density.scale)).monospacedDigit().foregroundStyle(.secondary)
            } else if let change = changes[entry.path] {
                if let stat = change.lineStat(staged: staged) {
                    GitDiffStats(additions: stat.additions, deletions: stat.deletions).fixedSize()
                } else {
                    Text(change.reviewStatus(staged: staged))
                        .font(.system(size: 12 * density.scale)).foregroundStyle(.secondary)
                }
            }
        }, decoration: { entry, _ in
            GitTreeActions(model: model, change: entry.type == .dir ? nil : changes[entry.path],
                           staged: staged, review: review, onDiscard: onDiscard,
                           breadcrumb: breadcrumb, scope: scope, entry: entry)
        })
    }
}

/// Header/layout updates reuse the existing tree; only a changed set of paths rebuilds it.
@MainActor private final class GitFileTreeCache {
    private var files: [GitFileChange] = []
    private var paths: [String] = []
    private var snapshot: GitChangeTree.FileSnapshot = ([], [:], [:])
    private var changes: [String: GitFileChange] = [:]

    func content(files: [GitFileChange], onBuild: () -> Void)
        -> (snapshot: GitChangeTree.FileSnapshot, changes: [String: GitFileChange]) {
        if self.files != files {
            self.files = files
            changes = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })
            let paths = files.map(\.path)
            if self.paths != paths {
                self.paths = paths
                snapshot = GitChangeTree(files: files).fileSnapshot
                onBuild()
            }
        }
        return (snapshot, changes)
    }
}

private struct GitTreeActions: ViewModifier {
    let model: GitModel
    let change: GitFileChange?
    let staged: Bool
    let review: Bool
    let onDiscard: (GitFileChange) -> Void
    let breadcrumb: GitScrollBreadcrumb?
    let scope: String
    let entry: FileEntry

    func body(content: Content) -> some View {
        decorated(content).background {
            if let breadcrumb {
                GitBreadcrumbMarker(tracker: breadcrumb, scope: scope, path: entry.path, directory: entry.type == .dir)
            }
        }
    }

    @ViewBuilder private func decorated(_ content: Content) -> some View {
        if let change {
            Group {
                if review {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        content
                        GitDiffPreview(model: model, change: change, staged: staged)
                    }
                } else { content }
            }
            .modifier(GitFileActions(model: model, change: change, staged: staged, onDiscard: { onDiscard(change) }))
            .accessibilityHint(change.origPath == nil ? change.reviewStatus(staged: staged) : change.reviewLocation ?? "")
        } else { content }
    }
}
