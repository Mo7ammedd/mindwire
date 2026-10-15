import XCTest
@testable import Mindwire

final class GitChangeTreeTests: XCTestCase {
    func testChangesKeepTheirPathsAndStatusesUnderTheRightFolders() throws {
        let files = [
            file("README.md"),
            file("src/components/Button.swift"),
            GitFileChange(path: "src/Legacy.swift", kind: "deleted", index: ".", worktree: "D"),
            GitFileChange(path: "tests/new name.swift", origPath: "old/name.swift", kind: "renamed", index: "R", worktree: "."),
        ]
        let tree = GitChangeTree(files: files)
        XCTAssertEqual(tree.roots.map(\.path), ["src", "tests", "README.md"])
        XCTAssertEqual(tree.roots.map(\.fileCount), [2, 1, 1])
        let rows = tree.rows(collapsed: [])
        let changes = rows.compactMap(\.node.change)
        XCTAssertEqual(Set(changes), Set(files), "No unchanged files or invented directory entries become Git changes")
        XCTAssertEqual(rows.first { $0.node.path == "src/components/Button.swift" }?.depth, 2)
        XCTAssertEqual(changes.first { $0.path == "tests/new name.swift" }?.origPath, "old/name.swift")
        XCTAssertFalse(tree.folders.contains("old"), "Renames are grouped at their destination and retain the old path in the row")
    }

    func testCollapsingAFolderKeepsSiblingsAndStableRowIdentities() {
        let tree = GitChangeTree(files: [file("src/A.swift"), file("src/nested/B.swift"), file("tests/A.swift"), file("root.swift")])
        let all = tree.rows(collapsed: [])
        let collapsed = tree.rows(collapsed: ["src"])
        XCTAssertEqual(collapsed.map(\.node.path), ["src", "tests", "tests/A.swift", "root.swift"])
        XCTAssertEqual(collapsed.map(\.id), all.filter { !["src/A.swift", "src/nested", "src/nested/B.swift"].contains($0.node.path) }.map(\.id))
        XCTAssertEqual(tree.rows(collapsed: tree.folders).count, 3)
    }

    func testReplacingAFileWithADirectoryDoesNotDuplicateIDsOrLoseTheDeletedFile() {
        let removed = GitFileChange(path: "config", kind: "deleted", index: ".", worktree: "D")
        let added = GitFileChange(path: "config/settings.json", kind: "untracked", index: "?", worktree: "?")
        let rows = GitChangeTree(files: [removed, added]).rows(collapsed: [])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertEqual(Set(rows.compactMap(\.node.change)), [removed, added])
    }

    func testCaseSensitiveDirectoriesAndNumericFileNamesStayStableAcrossRefreshOrder() {
        let files = [file("src/File10.swift"), file("src/File2.swift"), file("Src/File1.swift"), file("a.swift")]
        let forward = GitChangeTree(files: files).rows(collapsed: [])
        let reverse = GitChangeTree(files: files.reversed()).rows(collapsed: [])
        XCTAssertEqual(forward.map(\.id), reverse.map(\.id))
        XCTAssertEqual(forward.filter { $0.node.change != nil && $0.node.path.hasPrefix("src/") }.map(\.node.name),
                       ["File2.swift", "File10.swift"])
        XCTAssertEqual(Set(GitChangeTree(files: files).folders), ["src", "Src"])
    }

    func testLargeChangeSetsOnlyExposeVisibleRowsWhenCollapsed() {
        let files = (0..<10_000).map { file("packages/feature\($0 / 100)/File\($0).swift") }
        let tree = GitChangeTree(files: files)
        XCTAssertEqual(tree.roots.first?.fileCount, 10_000)
        XCTAssertEqual(tree.rows(collapsed: ["packages"]).count, 1)
        XCTAssertEqual(tree.rows(collapsed: []).compactMap(\.node.change).count, 10_000)
    }

    private func file(_ path: String) -> GitFileChange {
        .init(path: path, kind: "modified", index: ".", worktree: "M", unstaged: .init(additions: 2, deletions: 1))
    }
}
