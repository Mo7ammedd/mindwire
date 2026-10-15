#if DEBUG
import UIKit
import XCTest

final class ChatLanguageInteractionTests: XCTestCase {
    func testArabicChatAndComposerWithEnglishCode() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "chat", "MINDWIRE_STORE_THEME": "dark", "MINDWIRE_CHAT_TEST_LANGUAGE": "ar"]
        app.launch()
        XCTAssertTrue(app.otherElements["store.ready"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let code = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "let title")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10), app.debugDescription)
        capture("Arabic conversation, mixed prose and LTR code")
        composer.tap()
        composer.typeText("خلينا نراجع التغييرات")
        XCTAssertTrue((composer.value as? String)?.contains("خلينا") == true, app.debugDescription)
        capture("Arabic composer aligned to the right")
        app.terminate()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
