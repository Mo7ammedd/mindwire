#if DEBUG
import XCTest

final class FileMarkdownInteractionTests: XCTestCase {
    func testReadmeRendersAndCanSwitchToSourceAndEdit() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment["MINDWIRE_STORE_SCENE"] = "files"
        app.launchEnvironment["MINDWIRE_STORE_THEME"] = "dark"
        app.launchEnvironment["MINDWIRE_FILE_TEST_PATH"] = "/projects/orbit/README.md"
        app.launch()
        let preview = app.descendants(matching: .any)["file.markdownPreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        let heading = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", "Orbit", "Orbit")).firstMatch
        XCTAssertTrue(heading.exists, app.debugDescription)
        app.buttons["editor.actions"].tap()
        app.buttons["Show Source"].tap()
        let editor = app.descendants(matching: .any)["file.editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(preview.exists)
        app.buttons["editor.actions"].tap()
        app.buttons["Show Preview"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["editor.actions"].tap()
        app.buttons["Edit"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(preview.exists)
        app.terminate()
    }
}
#endif
