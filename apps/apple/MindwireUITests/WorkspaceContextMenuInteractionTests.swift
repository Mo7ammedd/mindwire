#if DEBUG
import UIKit
import XCTest

final class WorkspaceContextMenuInteractionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    func testEveryWorkspaceCardHasNativeActionsAndCreationKeepsItsWorkspace() {
        let app = launch()
        for (id, name) in [("store-mac", "MacBook Pro"), ("store-cloud", "Cloud Studio"), ("store-server", "Build Server")] {
            let card = app.descendants(matching: .any)["workspace.card.\(id)"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
            card.press(forDuration: 0.8)
            let create = app.buttons["New project"].firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["Open Workspace"].firstMatch.exists)
            XCTAssertTrue(app.buttons["Rename"].firstMatch.exists)
            XCTAssertTrue(app.buttons["Delete"].firstMatch.exists)
            capture("Native workspace actions for \(name)")
            create.tap()
            XCTAssertTrue(app.navigationBars["New project"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts[name].firstMatch.exists, "The selected workspace must be carried into creation")
            app.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(card.waitForExistence(timeout: 5))
        }
        app.terminate()
    }

    func testWorkspaceContextMenuRenameUsesTheSharedNativeDialog() {
        let app = launch()
        let card = app.descendants(matching: .any)["workspace.card.store-cloud"].firstMatch
        card.press(forDuration: 0.8)
        app.buttons["Rename"].firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Cloud Studio".count) + "Team Cloud")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(app.staticTexts["Team Cloud"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        capture("Workspace renamed from its native context menu")
        app.terminate()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "workspaces", "MINDWIRE_STORE_THEME": "dark"]
        app.launch()
        XCTAssertTrue(app.otherElements["store.ready"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["workspace.card.store-cloud"].firstMatch.waitForExistence(timeout: 5))
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
