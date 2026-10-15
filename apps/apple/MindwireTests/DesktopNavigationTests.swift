#if targetEnvironment(macCatalyst)
import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class DesktopNavigationTests: XCTestCase {
    private func makeStores() -> Stores {
        let suite = "desktop-navigation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    func testFileAndProjectRoutesOpenTheSameDesktopChatAndPreserveItsDraft() {
        let stores = makeStores()
        let app = AppModel(stores: stores)
        stores.chatDrafts.draft(for: "chat").text = "My unfinished request"
        app.openProject("project")
        XCTAssertEqual(app.desktopDestination, .projects)
        XCTAssertEqual(app.desktopPath.count, 1)
        app.push(.chat(chatId: "chat"))
        XCTAssertEqual(app.desktopDestination, .chat("chat"))
        XCTAssertTrue(app.desktopPath.isEmpty)
        XCTAssertEqual(stores.chatDrafts.draft(for: "chat").text, "My unfinished request")
        app.openWorkspace("computer")
        XCTAssertEqual(app.desktopDestination, .workspaces)
        XCTAssertEqual(app.desktopPath.count, 1)
    }

    func testWindowsKeepIndependentNavigationAndShareTheExistingChatCache() {
        let stores = makeStores()
        let first = AppModel(stores: stores)
        let second = AppModel(stores: stores)
        first.openChat("shared")
        second.openProject("project")
        let cached = first.stores.chatSessions.model(for: "shared")
        XCTAssertTrue(cached === second.stores.chatSessions.model(for: "shared"))
        XCTAssertEqual(first.desktopDestination, .chat("shared"))
        XCTAssertEqual(second.desktopDestination, .projects)
        first.selectDesktop(.newChat)
        XCTAssertEqual(second.desktopDestination, .projects)
        XCTAssertEqual(second.desktopPath.count, 1)
    }

    func testWelcomeSubmissionIsConsumedOnceAndCannotSendANewerDraft() {
        let app = AppModel(stores: makeStores())
        app.desktopSubmission = .init(chatID: "first", revision: 1)
        XCTAssertFalse(app.takeDesktopSubmission(chatID: "other", revision: 1))
        XCTAssertNotNil(app.desktopSubmission)
        XCTAssertTrue(app.takeDesktopSubmission(chatID: "first", revision: 1))
        XCTAssertFalse(app.takeDesktopSubmission(chatID: "first", revision: 1))
        app.desktopSubmission = .init(chatID: "first", revision: 1)
        XCTAssertFalse(app.takeDesktopSubmission(chatID: "first", revision: 2))
        XCTAssertNil(app.desktopSubmission)
    }
}
#endif
