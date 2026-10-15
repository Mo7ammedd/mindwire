import SwiftUI

/// VS Code-style Source Control decorations for the file browser: colors a changed file by its git
/// status and **propagates the color up to every ancestor folder**, so a folder shows it contains
/// changes. Fetched once per browse root via `ExecGitService`; a no-op when the root isn't a repo.
@Observable
@MainActor
final class GitDecorations {
    private var fileStatus: [String: (color: Color, letter: String)] = [:]  // file abs path → status
    private var folderColors: [String: Color] = [:]                          // ancestor folder → aggregate color

    /// The decoration color for an entry's NAME, or nil if it (or its subtree) has no git change.
    func color(for path: String, isDir: Bool) -> Color? {
        isDir ? folderColors[path] : fileStatus[path]?.color
    }

    /// A changed file's status color + VS Code letter (M/A/U/D/R/C/T), or nil if unchanged.
    func fileBadge(for path: String) -> (color: Color, letter: String)? { fileStatus[path] }

    /// Load `git status` for `root` and build the file + folder color maps. Root must be the repo
    /// top-level for paths to line up (true for a project workdir); otherwise this stays empty.
    func load(workspace: WorkspaceService, root: String) async {
        let git = ExecGitService(workspace: workspace, root: root)
        guard let status = try? await git.status(), status.isRepo else { return }
        let base = root == "/" ? "" : (root.hasSuffix("/") ? String(root.dropLast()) : root)
        var files: [String: (color: Color, letter: String)] = [:]
        var folders: [String: (color: Color, priority: Int)] = [:]
        for change in status.files {
            // git can report a wholly-untracked DIRECTORY as one entry with a trailing slash
            // ("app/test/") instead of its files — treat that as a changed FOLDER, not a file, so the
            // folder (and its ancestors) get colored rather than nothing matching the tree.
            let isDir = change.path.hasSuffix("/")
            let rel = isDir ? String(change.path.dropLast()) : change.path
            let abs = "\(base)/\(rel)"
            let deco = Self.decoration(for: change)
            if !isDir { files[abs] = (deco.color, deco.letter) }
            // Color the entry's own folder (if it IS a folder) and every ancestor up to the repo root,
            // keeping the highest-priority color per folder.
            var dir = isDir ? abs : (abs as NSString).deletingLastPathComponent
            while dir.hasPrefix(base), dir.count > base.count {
                if let existing = folders[dir] {
                    if deco.priority > existing.priority { folders[dir] = (deco.color, deco.priority) }
                } else {
                    folders[dir] = (deco.color, deco.priority)
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        fileStatus = files
        folderColors = folders.mapValues(\.color)
    }

    /// (color, priority, letter) — folders aggregate to the highest-priority contained change.
    private static func decoration(for change: GitFileChange) -> (color: Color, priority: Int, letter: String) {
        if change.isConflicted { return (removed, 4, "C") }
        if change.isUntracked { return (added, 1, "U") }
        let code = (change.index != "." ? change.index : change.worktree).uppercased()
        switch code {
        case "A": return (added, 1, "A")     // added
        case "D": return (removed, 3, "D")   // deleted
        case "R": return (modified, 2, "R")  // renamed
        case "C": return (modified, 2, "C")  // copied
        case "T": return (modified, 2, "T")  // type change
        default:  return (modified, 2, "M")  // modified
        }
    }

    // VS Code's own git-decoration palette — muted/desaturated, not the loud icon colors.
    static let modified = Color(red: 0.886, green: 0.753, blue: 0.553)   // #E2C08D  tan
    static let added = Color(red: 0.506, green: 0.722, blue: 0.545)      // #81B88B  muted green
    static let removed = Color(red: 0.780, green: 0.306, blue: 0.224)    // #C74E39  muted red
}
