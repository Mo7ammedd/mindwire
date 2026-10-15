#if targetEnvironment(macCatalyst)
import XCTest

final class DesktopInteractionTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testWelcomeDraftSurvivesSwitchingToAConversationAndBack() {
        let app = launch("desktop-home")
        let composer = app.descendants(matching: .any)["desktop.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("Organize the files for my next project")
        let conversation = app.buttons["desktop.chat.store-project-0-chat-0"].firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["desktop.newChat"].firstMatch.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Organize the files for my next project")
        attach(app, name: "mac-welcome-dark")
    }

    func testConversationUsesTheSharedTranscriptAndRestoresItsDraft() {
        let app = launch("desktop-chat", theme: "light")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText("Keep this follow-up while I check another chat")
        app.buttons["desktop.newChat"].firstMatch.tap()
        app.buttons["desktop.chat.store-project-0-chat-0"].firstMatch.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        XCTAssertEqual(composer.value as? String, "Keep this follow-up while I check another chat")
        attach(app, name: "mac-conversation-light")
    }

    private func launch(_ scene: String, theme: String = "dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": scene, "MINDWIRE_STORE_THEME": theme]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
