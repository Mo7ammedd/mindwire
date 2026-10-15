import Foundation
import Observation

/// Compact only single-directory chains. File paths and branching levels stay untouched.
struct FileTreeBranch {
    static let maximumComponents = 32
    let components: [FileEntry]
    let children: [FileEntry]?
    var entry: FileEntry { components[components.count - 1] }
    var title: String { components.map(\.name).joined(separator: " › ") }

    init(root: FileEntry, compact: Bool, children: (FileEntry) -> [FileEntry]?) {
        var components = [root]
        var current = root
        var seen: Set<String> = [root.path]
        var listing = root.type == .dir ? children(root) : nil
        while compact, components.count < Self.maximumComponents,
              let items = listing, items.count == 1, let child = items.first, child.type == .dir,
              seen.insert(child.path).inserted {
            components.append(child)
            current = child
            listing = children(current)
        }
        self.components = components
        self.children = listing
    }
}

/// Per-directory observations avoid re-rendering every row when one listing arrives.
@MainActor @Observable
final class FileTreeDirectory {
    var expanded = false
    private(set) var children: [FileEntry]?
    private(set) var loading = false
    @ObservationIgnored private var revision: Int?
    @ObservationIgnored private var pending: (id: UUID, revision: Int, task: Task<[FileEntry], Error>)?

    func load(revision: Int, read: @escaping () async throws -> [FileEntry]) async throws -> [FileEntry] {
        if self.revision == revision, let children { return children }
        if let pending, pending.revision == revision { return try await pending.task.value }
        pending?.task.cancel()
        let id = UUID()
        let task = Task { try await read() }
        pending = (id, revision, task)
        loading = true
        defer {
            if pending?.id == id { pending = nil; loading = false }
        }
        let result = try await task.value
        if pending?.id == id {
            children = result
            self.revision = revision
        }
        return result
    }
}

/// This cache lives only as long as the open tree. Collapsing a row or changing display
/// preferences reuses its listings; idle trees do not fetch or poll.
@MainActor
final class FileTreeDirectories {
    private var entries: [String: FileTreeDirectory] = [:]
    func directory(_ path: String) -> FileTreeDirectory {
        if let entry = entries[path] { return entry }
        let entry = FileTreeDirectory()
        entries[path] = entry
        return entry
    }
}
