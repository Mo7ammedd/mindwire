#if DEBUG && targetEnvironment(simulator)
import UIKit
import XCTest

/// Exercise the actual window and native controls, including keyboard input and device rotation.
final class iPadInteractionTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad interaction coverage")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testChatDraftSurvivesRotationAndSidebarToggle() {
        let app = launch("chat")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("Check keyboard navigation before shipping.")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(composer.value as? String, "Check keyboard navigation before shipping.")
        capture("Chat in portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let toggle = app.buttons["navigation.toggleSidebar"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertEqual(composer.value as? String, "Check keyboard navigation before shipping.")
        XCTAssertEqual(toggle.label, "Show sidebar")
        toggle.tap()
        XCTAssertEqual(composer.value as? String, "Check keyboard navigation before shipping.")
        XCTAssertEqual(toggle.label, "Hide sidebar")
        capture("Chat in landscape with keyboard")
        app.terminate()
    }

    func testEditorProtectsDraftWhenRotatingAndSelectingAnotherFile() {
        let app = launch("files")
        XCTAssertTrue(app.descendants(matching: .any)["file.editor"].firstMatch.waitForExistence(timeout: 15))
        let selectedFile = app.buttons["file.entry./projects/orbit/src/components/ActivityFeed.tsx"]
        XCTAssertTrue(selectedFile.waitForExistence(timeout: 5))
        XCTAssertTrue(selectedFile.isSelected, "The browser identifies the file open beside it")
        app.buttons["editor.actions"].tap()
        let edit = app.descendants(matching: .any)["editor.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), app.debugDescription)
        edit.tap()
        app.typeText("// Draft for iPad review\n")
        let save = app.buttons["editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(save.isEnabled, "Rotation must preserve an unsaved document")
        capture("Editor in portrait with unsaved changes")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.staticTexts["Dashboard.tsx"].firstMatch.tap()
        let alert = app.alerts["Discard unsaved changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(save.isEnabled, "Cancel keeps the original editor and its unsaved document")
        save.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: save)
        waitForExpectations(timeout: 5)
        capture("Editor in landscape after saving")
        app.terminate()
    }

    func testCommitStaysAvailableBesideTheDiffInLightAppearance() {
        let app = launch("review", theme: "light")
        XCTAssertTrue(app.descendants(matching: .any)["git.diff.editor"].firstMatch.waitForExistence(timeout: 15))
        let commit = app.buttons["git.openCommit"]
        XCTAssertTrue(commit.isHittable)
        capture("Source Control with visible Commit action")
        commit.tap()
        XCTAssertTrue(app.descendants(matching: .any)["git.commit.message"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(commit.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["git.diff.editor"].firstMatch.exists)
        app.terminate()
    }

    private func launch(_ scene: String, theme: String = "dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": scene, "MINDWIRE_STORE_THEME": theme]
        app.launch()
        XCTAssertTrue(app.otherElements["store.ready"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
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
