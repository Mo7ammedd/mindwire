#if DEBUG
import UIKit
import XCTest

/// Actual composer focus and UIKit transcript gestures, with delayed offline history responses.
final class ChatComposerInteractionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    func testUnsentTextSurvivesNavigatingBackAndReopeningTheChat() {
        let app = launch(content: "controls", agent: "codex", theme: "dark", scene: "chat")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        composer.tap()
        composer.typeText("Keep this unfinished message\nIncluding its second line")
        let original = composer.value as? String
        XCTAssertEqual(original, "Keep this unfinished message\nIncluding its second line")
        let navigation = app.navigationBars.firstMatch
        navigation.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Orbit"].waitForExistence(timeout: 5), app.debugDescription)
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Build a beautiful dashboard")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
        chat.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(composer.value as? String, original, "A new chat screen must recover the same unfinished text")
        capture("Unsent message restored after navigating back and reopening")
        app.terminate()
    }

    func testDoubleTapCopiesOneRenderedMarkdownWord() {
        let app = launch(content: "selection", agent: "codex", theme: "dark", scene: "chat")
        let reply = renderedText("Tap selection here.", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        reply.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 60, dy: reply.frame.height / 2)).doubleTap()
        let copy = app.menuItems["Copy"].firstMatch.waitForExistence(timeout: 2)
            ? app.menuItems["Copy"].firstMatch : app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3), "Double tap must select a rendered word in place.\n\(app.debugDescription)")
        capture("Rendered Markdown word selected with a double tap")
        copy.tap()
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        composer.tap()
        composer.press(forDuration: 0.8)
        let paste = app.menuItems["Paste"].firstMatch.waitForExistence(timeout: 2)
            ? app.menuItems["Paste"].firstMatch : app.buttons["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 3), app.debugDescription)
        paste.tap()
        XCTAssertEqual(composer.value as? String, "selection", "Copy must contain the selected word, without Markdown or the rest of the message")
        app.terminate()
    }

    func testLongPressStillOpensRawMarkdownSelection() {
        let app = launch(content: "selection", agent: "codex", theme: "light", scene: "chat")
        let reply = renderedText("Tap selection here.", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        reply.press(forDuration: 0.8)
        let select = app.menuItems["Select text"].firstMatch.waitForExistence(timeout: 2)
            ? app.menuItems["Select text"].firstMatch : app.buttons["Select text"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5), app.debugDescription)
        select.tap()
        XCTAssertTrue(app.navigationBars["Select text"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(renderedText("Tap **selection** here.", in: app).exists, "The separate selection sheet retains raw Markdown")
        capture("Raw Markdown remains available from Select Text")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        app.terminate()
    }

    func testLongAgentErrorsStartCollapsedAndKeepTheirFullDetailsAccessible() {
        for theme in ["dark", "light"] {
            let app = launch(content: "errors", agent: "codex", theme: theme, scene: "chat")
            let toggle = app.buttons["chat.error.toggle"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(toggle.value as? String, "Collapsed")
            XCTAssertFalse(app.alerts.firstMatch.exists, "Errors must not interrupt the chat with a giant modal")
            XCTAssertFalse(app.buttons["chat.error.details"].exists)
            capture("Compact agent error in \(theme) chat")
            toggle.tap()
            let details = app.buttons["chat.error.details"].firstMatch
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "Expanded")
            XCTAssertTrue(toggle.isHittable, "A long error must not push its collapse control out of reach")
            XCTAssertTrue(details.isHittable)
            capture("Bounded agent error details in \(theme) chat")
            details.tap()
            XCTAssertTrue(app.navigationBars["Agent error"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "END OF ERROR DETAILS")).firstMatch.exists,
                          "The full diagnostic must remain available beyond its inline preview")
            app.navigationBars["Agent error"].buttons["Done"].tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.tap()
            XCTAssertTrue(details.waitForNonExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "Collapsed")
            app.terminate()
        }
    }

    func testRejectedSendKeepsItsDraftAndShowsADismissibleCompactError() {
        let app = launch(content: "send-error", agent: "codex", theme: "dark", scene: "chat")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        composer.tap()
        composer.typeText("Try this request again")
        app.buttons["chat.send"].tap()
        let toggle = app.buttons["chat.error.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertEqual(composer.value as? String, "Try this request again")
        XCTAssertFalse(app.buttons["chat.stop"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture("Rejected send preserves the draft with a compact error")
        app.buttons["chat.error.dismiss"].tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Try this request again")
        app.terminate()
    }

    func testCodexLoadingTapDismissesKeyboardWithoutLosingDraft() {
        let app = launch(content: "controls", agent: "codex", theme: "dark")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        let loader = app.descendants(matching: .any)["chat-history-loading"].firstMatch
        XCTAssertTrue(loader.waitForExistence(timeout: 5), app.debugDescription)
        capture("Codex conversation loading in dark appearance")
        composer.tap()
        composer.typeText("Keep this draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        loader.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Loading content also dismisses focus")
        XCTAssertTrue(loader.exists, "The tap dismisses focus before history finishes loading")
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        app.terminate()
    }

    func testTranscriptTapsDismissKeyboardWithoutLosingDraftOrBlockingTools() {
        let app = launch(content: "controls", agent: "codex", theme: "dark", scene: "chat")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        let reply = renderedText("Your workspace is ready.", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        composer.tap()
        composer.typeText("Keep this draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText(" safely")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Taps inside the composer keep its keyboard")
        reply.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Tapping a reply dismisses the keyboard")
        XCTAssertEqual(composer.value as? String, "Keep this draft safely")
        capture("Transcript tap dismisses keyboard and preserves draft")

        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let commands = app.descendants(matching: .any)["chat.commandGroup"].firstMatch
        XCTAssertTrue(commands.waitForExistence(timeout: 5))
        // The custom disclosure makes its entire header one native button.
        (commands.elementType == .button ? commands : commands.buttons.firstMatch).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["pwd"].firstMatch.waitForExistence(timeout: 5),
                      "A single tap still expands the tool group while dismissing the keyboard")
        XCTAssertEqual(composer.value as? String, "Keep this draft safely")
        capture("Tool group responds to the same tap that dismisses keyboard")

        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let transcript = app.tables["chat.transcript"]
        // The gutter is outside the hosted message/button content, even when the keyboard is tall.
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Blank transcript space also dismisses focus")
        app.terminate()
    }

    func testClaudeLoadingAndEmptyConversationKeepKeyboardDismissal() {
        let app = launch(content: "empty", agent: "claude-code", theme: "light")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        let loader = app.descendants(matching: .any)["chat-history-loading"].firstMatch
        XCTAssertTrue(loader.waitForExistence(timeout: 5), app.debugDescription)
        capture("Claude conversation loading in light appearance")
        composer.tap()
        composer.typeText("A new conversation")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        loader.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(loader.exists, "The tap dismisses focus before history finishes loading")
        let empty = app.descendants(matching: .any)["chat.empty"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 25), app.debugDescription)
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        empty.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "A new conversation")
        capture("Empty conversation dismisses keyboard without clearing draft")
        app.terminate()
    }

    func testFollowupsShowSendBesideStopAndRecoverAfterCancellation() {
        for (agent, theme) in [("codex", "dark"), ("claude-code", "light")] {
            let app = launch(content: "queue", agent: agent, theme: theme, scene: "chat")
            let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
            let stop = app.buttons["chat.stop"].firstMatch
            let send = app.buttons["chat.send"].firstMatch
            XCTAssertTrue(stop.waitForExistence(timeout: 5), app.debugDescription)
            composer.tap()
            composer.typeText("Also check accessibility")
            XCTAssertTrue(send.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(stop.isHittable)
            XCTAssertTrue(send.isHittable)
            capture("\(agent) follow-up composer keeps Send and Stop")
            send.tap()
            let queue = app.buttons["chat.queue"].firstMatch
            XCTAssertTrue(queue.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(stop.exists)
            composer.tap()
            composer.typeText("Use the existing color palette")
            send.tap()
            XCTAssertTrue(app.staticTexts["2 queued"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            queue.tap()
            XCTAssertTrue(app.navigationBars["Message queue"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Also check accessibility"].firstMatch.exists)
            XCTAssertTrue(app.staticTexts["Use the existing color palette"].firstMatch.exists)
            capture("\(agent) compact queue and native message sheet")
            app.buttons["Done"].firstMatch.tap()
            stop.tap()
            XCTAssertTrue(stop.waitForNonExistence(timeout: 5), app.debugDescription)
            queue.tap()
            let restore = app.buttons["Use as Draft"].firstMatch
            XCTAssertTrue(restore.waitForExistence(timeout: 5), app.debugDescription)
            restore.tap()
            XCTAssertEqual(composer.value as? String, "Also check accessibility")
            capture("\(agent) stopped follow-up restored as draft")
            app.terminate()
        }
    }

    func testNotificationCenterKeepsExpandedToolsAndDraft() {
        let app = launch(content: "controls", agent: "codex", theme: "dark", scene: "chat")
        let commands = app.descendants(matching: .any)["chat.commandGroup"].firstMatch
        XCTAssertTrue(commands.waitForExistence(timeout: 5))
        (commands.elementType == .button ? commands : commands.buttons.firstMatch).tap()
        XCTAssertTrue(app.staticTexts["pwd"].firstMatch.waitForExistence(timeout: 5))
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        composer.tap()
        composer.typeText("Keep this draft")
        renderedText("Your workspace is ready.", in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        // Exercise the real system gesture. Do not capture or inspect private
        // Notification Center content; assertions and screenshots cover the app.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.01))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.85))
        top.press(forDuration: 0.1, thenDragTo: bottom)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
            .press(forDuration: 0.1, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.isHittable, "Notification Center must be dismissed before checking the chat")
        XCTAssertTrue(app.staticTexts["pwd"].firstMatch.exists, "System overlays must not reset expanded tools")
        XCTAssertEqual(composer.value as? String, "Keep this draft")
        app.terminate()
    }

    func testSelfHostedFilesCanNavigateAboveRootHome() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "server-files", "MINDWIRE_STORE_THEME": "dark"]
        app.launch()
        let home = app.navigationBars["root"]
        XCTAssertTrue(home.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["file.entry./root/README.md"].firstMatch.waitForExistence(timeout: 5))
        capture("Server Files starts at home with a parent navigation button")
        home.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["file.entry./etc"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["file.entry./home"].firstMatch.exists)
        capture("Server Files can browse the filesystem root")
        app.terminate()
    }

    private func renderedText(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value == %@ OR label == %@", text, text)).firstMatch
    }

    private func launch(content: String, agent: String, theme: String, scene: String = "chat-loading") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": scene, "MINDWIRE_STORE_THEME": theme,
                                 "MINDWIRE_CHAT_TEST_CONTENT": content, "MINDWIRE_CHAT_AGENT": agent,
                                 "MINDWIRE_CHAT_HISTORY_DELAY": scene == "chat-loading" ? "30" : "0"]
        app.launch()
        XCTAssertTrue(app.otherElements["store.ready"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer"].firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
