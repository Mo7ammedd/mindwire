import Foundation

/// A tree of the status already returned by Git. Deleted files and rename destinations stay
/// visible even when they do not exist on disk. Building or expanding it never reads files.
struct GitChangeTree {
    struct Node: Identifiable {
        let path: String
        let name: String
        let change: GitFileChange?
        let children: [Node]
        let fileCount: Int
        var id: String { (change == nil ? "folder:" : "file:") + path }
    }

    struct Row: Identifiable {
        let node: Node
        let depth: Int
        var id: String { node.id }
    }

    let roots: [Node]
    let folders: Set<String>

    /// Adapt status paths to the file explorer's data source, including deleted paths.
    typealias FileSnapshot = (roots: [FileEntry], children: [String: [FileEntry]], counts: [String: Int])

    var fileSnapshot: FileSnapshot {
        func entry(_ node: Node) -> FileEntry {
            FileEntry(name: node.name, path: node.path, type: node.change == nil ? .dir : .file)
        }
        var children: [String: [FileEntry]] = [:]
        var counts: [String: Int] = [:]
        func visit(_ nodes: [Node]) {
            for node in nodes where node.change == nil {
                children[node.path] = node.children.map(entry)
                counts[node.path] = node.fileCount
                visit(node.children)
            }
        }
        visit(roots)
        return (roots.map(entry), children, counts)
    }

    init(files: [GitFileChange]) {
        let root = Folder()
        var folders: Set<String> = []
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var parent = root
            var prefix = ""
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                folders.insert(prefix)
                if parent.folders[part] == nil { parent.folders[part] = Folder(path: prefix, name: part) }
                parent = parent.folders[part]!
            }
            parent.files.append(file)
        }
        roots = root.nodes()
        self.folders = folders
    }

    /// Flat visible rows preserve List's recycling instead of nesting the whole tree in a
    /// single row. IDs do not depend on order, counts, progress, or whether a folder is open.
    func rows(collapsed: Set<String>) -> [Row] {
        var result: [Row] = []
        func visit(_ nodes: [Node], depth: Int) {
            for node in nodes {
                result.append(Row(node: node, depth: depth))
                if node.change == nil && !collapsed.contains(node.path) { visit(node.children, depth: depth + 1) }
            }
        }
        visit(roots, depth: 0)
        return result
    }

    private final class Folder {
        let path: String
        let name: String
        var folders: [String: Folder] = [:]
        var files: [GitFileChange] = []
        init(path: String = "", name: String = "") { self.path = path; self.name = name }

        func nodes() -> [Node] {
            folders.values.sorted { Self.before($0.name, $1.name) }.map {
                let children = $0.nodes()
                return Node(path: $0.path, name: $0.name, change: nil, children: children,
                            fileCount: children.reduce(0) { $0 + $1.fileCount })
            } + files.sorted {
                Self.before($0.name, $1.name)
            }.map { Node(path: $0.path, name: $0.name, change: $0, children: [], fileCount: 1) }
        }

        private static func before(_ first: String, _ second: String) -> Bool {
            let order = first.localizedStandardCompare(second)
            return order == .orderedSame ? first < second : order == .orderedAscending
        }
    }
}
