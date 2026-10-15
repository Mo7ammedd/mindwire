#if DEBUG
import XCTest

final class ChatLinkInteractionTests: XCTestCase {
    func testWorkspaceFilesImagesAndWebLinksOpenFromChat() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "chat", "MINDWIRE_STORE_THEME": "dark",
                                 "MINDWIRE_CHAT_TEST_CONTENT": "links"]
        app.launch()
        let source = app.links["Open source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15), app.debugDescription)
        source.tap()
        XCTAssertTrue(app.descendants(matching: .any)["file.editor"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.navigationBars["ActivityFeed.tsx"].exists)
        capture("Source citation opened in the existing editor")
        closeFiles(app)

        app.links["Open screenshot"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["file.imagePreview"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        capture("Workspace image opened directly from a chat link")
        closeFiles(app)

        app.links["Open folder"].firstMatch.tap()
        XCTAssertTrue(app.buttons["file.entry./projects/orbit/src/components/ActivityFeed.tsx"].waitForExistence(timeout: 8), app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))

        app.links["Open website"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.link.browser"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        let closeBrowser = app.buttons["Close"].firstMatch
        XCTAssertTrue(closeBrowser.waitForExistence(timeout: 8), app.debugDescription)
        capture("Web link opened in the native in-app browser")
        closeBrowser.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.terminate()
    }

    private func closeFiles(_ app: XCUIApplication) {
        let done = app.buttons["files.closePreview"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        done.tap()
        XCTAssertTrue(app.links["Open source"].firstMatch.waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
#endif
