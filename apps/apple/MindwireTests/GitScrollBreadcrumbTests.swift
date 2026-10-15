import XCTest
@testable import Mindwire

final class GitScrollBreadcrumbTests: XCTestCase {
    func testReadingEdgeFollowsNestedFoldersInBothDirections() {
        let rows = [
            row("apps/api", y: 80, height: 40),
            row("apps/api/modules", y: 120, height: 280), // A partly visible Review preview.
            row("apps/web", y: 400, height: 40)
        ]
        func folder(_ top: CGFloat) -> String {
            GitBreadcrumbPosition.context(top: top, bottom: top + 600, rows: rows)?.folder ?? ""
        }
        XCTAssertEqual(folder(40), "apps/api")
        XCTAssertEqual(folder(120), "apps/api/modules")
        XCTAssertEqual(folder(250), "apps/api/modules", "A tall preview keeps the same context until it scrolls past the header")
        XCTAssertEqual(folder(410), "apps/web")
        XCTAssertEqual(folder(160), "apps/api/modules")
        XCTAssertEqual(folder(40), "apps/api")
    }

    func testOverviewAndSectionLabelsClearThePinnedContext() {
        let rows = [row("", y: 0, height: 30, scope: ""),
                    row("", y: 30, height: 30, scope: "staged", header: true),
                    row("prepared", y: 60, height: 30, scope: "staged"),
                    row("", y: 90, height: 30, header: true),
                    row("apps/web", y: 120, height: 30)]
        func context(_ top: CGFloat) -> GitBreadcrumbContext? {
            GitBreadcrumbPosition.context(top: top, bottom: 600, rows: rows)
        }
        XCTAssertNil(context(0))
        XCTAssertNil(context(40), "The section title is already visible in the list")
        XCTAssertEqual(context(70), GitBreadcrumbContext(scope: "staged", folder: "prepared"))
        XCTAssertNil(context(100), "Crossing the next section label clears the old context")
        XCTAssertEqual(context(130), GitBreadcrumbContext(scope: "working", folder: "apps/web"))
        XCTAssertNil(context(160))
        XCTAssertEqual(GitBreadcrumbPosition.context(top: 40, bottom: 600, rows: [row("", y: 40, height: 30)]),
                       GitBreadcrumbContext(scope: "working", folder: ""), "A root file keeps its section without a stale folder")
    }

    func testContextUsesTheRealDestinationPathWithoutRemovingFolderComponents() {
        XCTAssertEqual(GitBreadcrumbRow.folder(path: "apps/api/modules/file.ts", directory: false), "apps/api/modules")
        XCTAssertEqual(GitBreadcrumbRow.folder(path: "apps/api/modules", directory: true), "apps/api/modules")
        XCTAssertEqual(GitBreadcrumbRow.folder(path: "README.md", directory: false), "")
    }

    private func row(_ folder: String, y: CGFloat, height: CGFloat, scope: String = "working", header: Bool = false) -> GitBreadcrumbRow {
        GitBreadcrumbRow(scope: scope, folder: folder, frame: CGRect(x: 0, y: y, width: 300, height: height), header: header)
    }
}
