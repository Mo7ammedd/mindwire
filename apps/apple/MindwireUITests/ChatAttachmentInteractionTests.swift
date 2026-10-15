#if DEBUG
import XCTest
import UIKit

final class ChatAttachmentInteractionTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }

    func testAttachmentsAboveTextAndImagePreviewOnIPhone() {
        let app = launch()
        let image = app.buttons.matching(identifier: "chat.attachment").matching(NSPredicate(format: "label == %@", "design.jpg")).firstMatch
        let text = app.textViews.matching(NSPredicate(format: "value == %@", "Review this design and the attached notes.")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(text.exists)
        XCTAssertLessThan(image.frame.maxY, text.frame.minY)
        capture("Sent image and file above message text")
        image.tap()
        XCTAssertTrue(app.navigationBars["design.jpg"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        let file = app.buttons.matching(identifier: "chat.attachment").matching(NSPredicate(format: "label == %@", "requirements.txt")).firstMatch
        XCTAssertTrue(file.isHittable)
        file.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
        capture("Native file preview keeps its Done control")
        done.tap()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        app.terminate()
    }

    func testLongCommandCanCollapseFromFooterHeaderAndContextMenu() {
        let app = launch()
        let tool = app.descendants(matching: .any)["chat.tool.long-command"].firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 10), app.debugDescription)
        header(tool).tap()
        let fullOutput = app.buttons["chat.tool.fullOutput"].firstMatch
        reveal(fullOutput, app: app)
        fullOutput.tap()
        XCTAssertTrue(app.navigationBars["Output"].waitForExistence(timeout: 5))
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.isHittable)
        app.descendants(matching: .any)["chat.tool.output"].firstMatch.swipeUp()
        XCTAssertTrue(done.isHittable, "Full output never scrolls away the close control")
        capture("Full command output with fixed Done control")
        done.tap()
        let collapse = app.buttons["chat.tool.collapse"].firstMatch
        reveal(collapse, app: app)
        collapse.tap()
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 5))
        reveal(header(tool), app: app)
        header(tool).tap()
        reveal(header(tool), app: app)
        header(tool).tap()
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 5), "Tapping the whole header collapses it")
        header(tool).tap()
        reveal(header(tool), app: app)
        header(tool).press(forDuration: 0.8)
        let menuCollapse = app.buttons["Collapse"].firstMatch
        XCTAssertTrue(menuCollapse.waitForExistence(timeout: 5), app.debugDescription)
        menuCollapse.tap()
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 5))
        capture("Collapsed command preserves the conversation")
        app.terminate()
    }

    func testPhotoAndFilePickersAreAvailableThroughAttachmentMenu() {
        let app = launch()
        app.buttons["chat.tools"].firstMatch.tap()
        let attachment = app.buttons["chat.addImage"].firstMatch
        XCTAssertTrue(attachment.waitForExistence(timeout: 5), app.debugDescription)
        attachment.tap()
        XCTAssertTrue(app.buttons["Take Photo"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Choose Files"].firstMatch.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["chat.tools"].firstMatch.tap()
        XCTAssertTrue(attachment.waitForExistence(timeout: 5))
        attachment.tap()
        app.buttons["Photo Library"].firstMatch.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "chat", "MINDWIRE_STORE_THEME": "dark",
                                 "MINDWIRE_CHAT_TEST_CONTENT": "attachments", "MINDWIRE_CHAT_AGENT": "codex"]
        app.launch()
        XCTAssertTrue(app.otherElements["store.ready"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable { app.tables.firstMatch.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    private func header(_ tool: XCUIElement) -> XCUIElement {
        tool.elementType == .button ? tool : tool.buttons.firstMatch
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
