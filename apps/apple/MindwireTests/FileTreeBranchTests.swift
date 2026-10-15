import XCTest
@testable import Mindwire

final class FileTreeBranchTests: XCTestCase {
    func testCompactChainsKeepFilesAndStopAtBranches() {
        let apps = dir("apps"), src = dir("apps/src"), modules = dir("apps/src/modules")
        let file = FileEntry(name: "index.ts", path: "apps/src/modules/index.ts", type: .file)
        var listing = [apps.path: [src], src.path: [modules], modules.path: [file]]
        let branch = FileTreeBranch(root: apps, compact: true) { listing[$0.path] }
        XCTAssertEqual(branch.title, "apps › src › modules")
        XCTAssertEqual(branch.entry.path, modules.path)
        XCTAssertEqual(branch.children?.map(\.path), [file.path])

        listing[src.path] = [modules, dir("apps/src/tests")]
        let split = FileTreeBranch(root: apps, compact: true) { listing[$0.path] }
        XCTAssertEqual(split.title, "apps › src")
        XCTAssertEqual(split.children?.map(\.path), [modules.path, "apps/src/tests"])

        listing[apps.path] = [src, FileEntry(name: "README.md", path: "apps/README.md", type: .file)]
        XCTAssertEqual(FileTreeBranch(root: apps, compact: true) { listing[$0.path] }.components.count, 1)
        listing[apps.path] = [src]
        XCTAssertEqual(FileTreeBranch(root: apps, compact: false) { listing[$0.path] }.children?.map(\.path), [src.path])
    }

    func testUnknownEmptyAndVeryDeepDirectoriesRemainReachable() {
        let root = dir("apps"), child = dir("apps/src")
        let unloaded = FileTreeBranch(root: root, compact: true) { $0.path == root.path ? [child] : nil }
        XCTAssertEqual(unloaded.entry.path, child.path)
        XCTAssertNil(unloaded.children, "Unknown directories must not be treated as empty or fetched by the resolver")
        let empty = FileTreeBranch(root: root, compact: true) { _ in [] }
        XCTAssertEqual(empty.components.count, 1)
        XCTAssertEqual(empty.children?.count, 0)
        let cycle = FileTreeBranch(root: root, compact: true) { $0.path == root.path ? [child] : [root] }
        XCTAssertEqual(cycle.components.map(\.path), [root.path, child.path])

        let entries = (1...40).map { dir(Array(repeating: "a", count: $0).joined(separator: "/")) }
        let listing = Dictionary(uniqueKeysWithValues: zip(entries, entries.dropFirst()).map { ($0.path, [$1]) })
        let deep = FileTreeBranch(root: entries[0], compact: true) { listing[$0.path] }
        XCTAssertEqual(deep.components.count, FileTreeBranch.maximumComponents)
        XCTAssertEqual(deep.children?.first?.path, entries[FileTreeBranch.maximumComponents].path,
                       "A bounded compact group must leave the remaining levels accessible")
    }

    @MainActor
    func testConcurrentDirectoryReadsShareOneRequestAndReuseItsRevision() async throws {
        let directory = FileTreeDirectory()
        let started = expectation(description: "Directory read started")
        let joined = expectation(description: "Second consumer joined")
        var reply: CheckedContinuation<[FileEntry], Error>?
        var reads = 0
        let read: () async throws -> [FileEntry] = {
            reads += 1
            return try await withCheckedThrowingContinuation { continuation in
                reply = continuation
                started.fulfill()
            }
        }
        let first = Task { try await directory.load(revision: 1, read: read) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task {
            joined.fulfill()
            return try await directory.load(revision: 1, read: read)
        }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertTrue(directory.loading)
        XCTAssertEqual(reads, 1)
        reply?.resume(returning: [dir("apps/src")])
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult.map(\.path), secondResult.map(\.path))
        let cached = try await directory.load(revision: 1) { reads += 1; return [] }
        XCTAssertEqual(cached.map(\.path), ["apps/src"])
        XCTAssertEqual(reads, 1, "Reopening a folder or changing spacing must not repeat its read")
        XCTAssertFalse(directory.loading)
    }

    @MainActor
    func testObsoleteAndFailedReadsCannotReplaceTheLatestListing() async throws {
        let directory = FileTreeDirectory()
        let started = expectation(description: "Old directory read started")
        var reply: CheckedContinuation<[FileEntry], Error>?
        let old = Task {
            try await directory.load(revision: 1) {
                try await withCheckedThrowingContinuation { continuation in
                    reply = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        _ = try await directory.load(revision: 2) { [self.dir("apps/new")] }
        reply?.resume(returning: [dir("apps/old")])
        _ = try await old.value
        XCTAssertEqual(directory.children?.map(\.path), ["apps/new"])
        XCTAssertFalse(directory.loading)
        do {
            _ = try await directory.load(revision: 3) { throw URLError(.networkConnectionLost) }
            XCTFail("The failed read must be reported to its caller")
        } catch { }
        XCTAssertEqual(directory.children?.map(\.path), ["apps/new"])
        XCTAssertFalse(directory.loading)
        _ = try await directory.load(revision: 3) { [self.dir("apps/recovered")] }
        XCTAssertEqual(directory.children?.map(\.path), ["apps/recovered"])
    }

    private func dir(_ path: String) -> FileEntry {
        FileEntry(name: (path as NSString).lastPathComponent, path: path, type: .dir)
    }
}
