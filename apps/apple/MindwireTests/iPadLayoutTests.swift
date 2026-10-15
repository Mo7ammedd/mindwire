#if DEBUG && targetEnvironment(simulator)
import Runestone
import SwiftUI
import UIKit
import XCTest
@testable import Mindwire

@MainActor
final class iPadLayoutTests: XCTestCase {
    func testChatKeepsItsDraftTranscriptAndHistoryAcrossWindowSizes() async throws {
        let fixture = try await AppStoreFixture()
        defer { fixture.close() }
        fixture.app.projectsPath.append(AppRoute.chat(chatId: fixture.chatID))
        let window = try await mount(MainScene(repository: fixture.repository), fixture: fixture)
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController)
        let model = fixture.stores.chatSessions.model(for: fixture.chatID)
        try await wait { model.hasLoadedHistory }
        let table = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITableView }.last)
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first { $0.isEditable })
        field.becomeFirstResponder()
        field.insertText("Check the dark appearance before shipping.")
        field.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(100))
        let reads = await fixture.channel.historyReads
        for width: CGFloat in [600, 1_032, 1_376] {
            await resize(window, width: width)
            let currentTable = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITableView }.last)
            let currentField = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first { $0.isEditable })
            XCTAssertTrue(currentTable === table, "Resizing must keep the existing virtualized transcript")
            XCTAssertEqual(currentField.text, "Check the dark appearance before shipping.")
            XCTAssertTrue(model.session === fixture.session)
        }
        let after = await fixture.channel.historyReads
        XCTAssertEqual(after, reads, "Adding or removing a sidebar must not fetch history again")
    }

    func testFileEditorKeepsItsDocumentAndDoesNotReadAgainWhenColumnsCollapse() async throws {
        let fixture = try await AppStoreFixture()
        defer { fixture.close() }
        let path = "/projects/orbit/src/components/ActivityFeed.tsx"
        let window = try await mount(FilesSheet(workspace: fixture.files, basePath: "/projects/orbit",
            title: "Orbit", initialFile: path), fixture: fixture)
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController)
        try await wait { self.editor(in: window) != nil }
        let original = try XCTUnwrap(editor(in: host.view))
        let contents = original.text
        let reads = fixture.files.reads
        for width: CGFloat in [600, 1_032, 1_376] {
            await resize(window, width: width)
            let current = try XCTUnwrap(editor(in: host.view))
            XCTAssertTrue(current === original, "The split view must retain the live editor")
            XCTAssertEqual(current.text, contents)
        }
        XCTAssertEqual(fixture.files.reads, reads)
        XCTAssertNil(fixture.files.saved[path], "Resize must not write a file")
    }

    func testSourceControlKeepsFileListAndFollowsTheSelectedFileAfterStaging() async throws {
        let fixture = try await AppStoreFixture()
        defer { fixture.close() }
        let model = await fixture.gitModel()
        defer { Task { await model.dispose() } }
        let window = try await mount(SourceControlScreen(workspaceId: fixture.workspaces[0].id, model: model,
            selection: .init(change: StoreGitService.primary, staged: false)), fixture: fixture)
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController)
        try await wait { self.editor(in: window) != nil }
        let original = try XCTUnwrap(editor(in: host.view))
        let list = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UICollectionView }.first)
        await resize(window, width: 1_032)
        XCTAssertTrue(editor(in: host.view) === original)
        let succeeded = await model.stage([StoreGitService.primary.path])
        XCTAssertTrue(succeeded)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(descendants(host.view).compactMap { $0 as? UICollectionView }.contains { $0 === list },
                      "Staging must update the existing file list in place")
        XCTAssertTrue(model.staged.contains { $0.path == StoreGitService.primary.path })
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(text.contains("Dashboard.tsx"))
        XCTAssertTrue(text.contains(t("git.unstage")), "The editor follows the file into Staged")
        XCTAssertNotNil(editor(in: host.view))
    }

    func testReadingWidthAndDesktopControlsFitNarrowAndWideWindows() {
        XCTAssertFalse(AdaptiveLayout.usesColumns(width: 600, regular: true))
        XCTAssertTrue(AdaptiveLayout.usesColumns(width: 1_032, regular: true))
        XCTAssertFalse(AdaptiveLayout.usesColumns(width: 1_032, regular: true, accessibility: true))
        for size in [CGSize(width: 600, height: 700), .init(width: 1_032, height: 1_200), .init(width: 1_376, height: 900)] {
            let layout = DesktopControlLayout(available: size, pixels: .init(width: 1_440, height: 900), mode: .touchpad, fullscreen: false)
            if layout.sideBySide {
                XCTAssertLessThanOrEqual(layout.sideVideoWidth + layout.sideWidth + 40, size.width + 1)
            } else {
                XCTAssertLessThanOrEqual(layout.videoHeight + layout.padHeight + 32, size.height + 1)
            }
        }
        if UIDevice.current.userInterfaceIdiom == .pad { XCTAssertEqual(DesktopOrientations.supported(for: nil), .all) }
    }

    private func mount<V: View>(_ content: V, fixture: AppStoreFixture) async throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: content.environment(fixture.app).environment(\.stores, fixture.stores)
            .environment(\.scenePhase, .inactive).preferredColorScheme(.dark).tint(Palette.accent))
        host.traitOverrides.horizontalSizeClass = .regular
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1_376, height: 1_032)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(1_200))
        return window
    }

    private func resize(_ window: UIWindow, width: CGFloat) async {
        window.rootViewController?.traitOverrides.horizontalSizeClass = width < 840 ? .compact : .regular
        window.frame.size = CGSize(width: width, height: 1_032)
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(350))
    }

    private func editor(in view: UIView) -> DiffGutterTextView? {
        descendants(view).compactMap { $0 as? DiffGutterTextView }.first
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The view did not become ready")
        throw URLError(.timedOut)
    }
}
#endif
