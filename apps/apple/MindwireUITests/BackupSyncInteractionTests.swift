#if DEBUG
import UIKit
import XCTest

final class BackupSyncInteractionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    func testOptInCredentialControlsAndNativeDeletionKeepLocalConnections() {
        for theme in ["dark", "light"] {
            let app = XCUIApplication()
            app.launchArguments = ["--app-store-preview"]
            app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "backup", "MINDWIRE_STORE_THEME": theme]
            app.launch()
            let toggle = app.switches["backup.icloud-toggle"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertEqual(toggle.value as? String, "0")
            tapSwitch(toggle)
            let credentials = app.switches["backup.credentials-toggle"].firstMatch
            XCTAssertTrue(credentials.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(credentials.value as? String, "0", "Server secrets require explicit opt-in")
            XCTAssertTrue(app.staticTexts["Up to date"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            capture("iCloud sync settings · \(theme)")
            tapSwitch(credentials)
            XCTAssertEqual(credentials.value as? String, "1")
            app.buttons["What’s Saved"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars["What’s Saved"].waitForExistence(timeout: 5))
            capture("What iCloud saves · \(theme)")
            app.buttons["Done"].firstMatch.tap()
            let delete = app.buttons["backup.delete-cloud"].firstMatch
            if !delete.isHittable { app.swipeUp() }
            delete.tap()
            let alert = app.alerts["Delete iCloud Data?"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            alert.buttons["Cancel"].tap()
            XCTAssertEqual(toggle.value as? String, "1")
            delete.tap()
            alert.buttons["Delete iCloud Data"].tap()
            if !toggle.isHittable { app.swipeDown() }
            XCTAssertEqual(toggle.value as? String, "0")
            XCTAssertTrue(app.staticTexts["Computers & Servers, 3"].firstMatch.exists, "Deleting the cloud backup keeps local connections")
            app.terminate()
        }
    }

    func testEncryptedBackupRoundTripThroughNativeFiles() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "backup", "MINDWIRE_STORE_THEME": "light"]
        app.launch()
        let export = app.buttons["backup.export"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 20), app.debugDescription)
        if !export.isHittable { app.swipeUp() }
        export.tap()
        let password = app.secureTextFields["backup.file.password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["backup.file.continue"].isEnabled)
        password.tap()
        password.typeText("My long backup password")
        let confirm = app.secureTextFields["backup.file.confirm-password"].firstMatch
        confirm.tap()
        confirm.typeText("My long backup password")
        let next = app.buttons["backup.file.continue"]
        if !next.isHittable { app.swipeUp() }
        XCTAssertTrue(next.isEnabled)
        capture("Password protected backup file")
        next.tap()
        let files = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS[c] %@", "Save")).firstMatch
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10) || files.exists, app.debugDescription)
        capture("Native Files destination picker")
        let filename = "Mindwire-Backup-Test-" + String(UUID().uuidString.prefix(8))
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100) + filename)
        save.tap()
        XCTAssertTrue(app.staticTexts["Backup saved."].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.terminate()
        app.launch()
        let restore = app.buttons["backup.import"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 20))
        if !restore.isHittable { app.swipeUp() }
        restore.tap()
        // Files starts on Recents after reinstall/relaunch. Newly exported
        // documents need not be indexed there, so browse their local location.
        let browse = app.tabBars["DOC.browsingModeTabBar"].buttons["Browse"]
        if browse.waitForExistence(timeout: 2) { browse.tap() }
        let local = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR label == %@", "On My iPhone", "On My iPad")).firstMatch
        if local.waitForExistence(timeout: 3) { local.tap() }
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", filename)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        file.tap()
        let unlockPassword = app.secureTextFields["backup.file.password"].firstMatch
        XCTAssertTrue(unlockPassword.waitForExistence(timeout: 5), app.debugDescription)
        unlockPassword.tap()
        unlockPassword.typeText("Incorrect backup password")
        app.buttons["backup.file.continue"].tap()
        XCTAssertTrue(app.staticTexts["The password is incorrect or the backup is damaged. Try again."].waitForExistence(timeout: 5))
        unlockPassword.tap()
        unlockPassword.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100) + "My long backup password")
        app.buttons["backup.file.continue"].tap()
        XCTAssertTrue(app.staticTexts["Saved Connections, 3"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        capture("Decrypted backup preview keeps existing connections")
        app.buttons["backup.file.continue"].tap()
        XCTAssertTrue(app.staticTexts["Backup restored."].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.terminate()
    }

    private func tapSwitch(_ toggle: XCUIElement) {
        if toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() }
        else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
    }

    func testCachedConversationUsesTitleIndicatorAndKeepsItsTranscriptOnReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "chat", "MINDWIRE_STORE_THEME": "dark",
            "MINDWIRE_CHAT_TEST_CONTENT": "controls", "MINDWIRE_CHAT_HISTORY_DELAY": "8",
            "MINDWIRE_CHAT_DELAY_AFTER_FIRST": "1"]
        app.launch()
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Your workspace is ready.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), app.debugDescription)
        let indicator = app.descendants(matching: .any)["chat-history-refreshing"].firstMatch
        _ = indicator.waitForNonExistence(timeout: 15)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(indicator.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(indicator.frame.maxY, 180, "History refresh belongs in the title, above the transcript")
        XCTAssertTrue(reply.exists, "Cached messages remain visible throughout the freshness check")
        XCTAssertFalse(app.descendants(matching: .any)["chat-history-loading"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Loading latest…"].exists)
        capture("Cached conversation with title-only refresh")
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 15))
        XCTAssertTrue(reply.exists)
        app.terminate()
    }

    func testCachedRefreshKeepsLoadingInTheChatListAfterBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "chat", "MINDWIRE_STORE_THEME": "dark",
            "MINDWIRE_CHAT_TEST_CONTENT": "controls", "MINDWIRE_CHAT_HISTORY_DELAY": "20",
            "MINDWIRE_CHAT_DELAY_AFTER_FIRST": "1"]
        app.launch()
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Your workspace is ready.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), app.debugDescription)
        XCUIDevice.shared.press(.home)
        app.activate()
        let title = app.descendants(matching: .any)["chat-history-refreshing"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        let loading = app.descendants(matching: .any)["chat-row-loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 5), app.debugDescription)
        capture("Chat list retains cached refresh indicator after Back")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Build a beautiful dashboard")).firstMatch.tap()
        XCTAssertTrue(reply.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(title.exists)
        XCTAssertTrue(title.waitForNonExistence(timeout: 30))
        app.terminate()
    }

    func testOlderPagingUsesTheScrollerAndContinuesDuringLatestRefresh() {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "chat", "MINDWIRE_STORE_THEME": "dark",
            "MINDWIRE_CHAT_TEST_CONTENT": "paged-history", "MINDWIRE_CHAT_HISTORY_DELAY": "24",
            "MINDWIRE_CHAT_OLDER_HISTORY_DELAY": "8", "MINDWIRE_CHAT_DELAY_AFTER_FIRST": "1"]
        app.launch()
        let table = app.tables["chat.transcript"]
        XCTAssertTrue(table.waitForExistence(timeout: 20), app.debugDescription)
        // Match animation state in one native accessibility snapshot. A stopped,
        // offscreen UITableView header can remain cached even after its view is removed.
        let older = table.descendants(matching: .activityIndicator).matching(NSPredicate(
            format: "identifier == %@ AND value == %@", "chat-history-older-loading", "1")).firstMatch
        let title = app.descendants(matching: .any)["chat-history-refreshing"].firstMatch
        scrollToOlder(table, indicator: older)
        XCTAssertTrue(older.exists)
        XCTAssertFalse(title.exists, "Paging older messages must not show a title refresh")
        capture("Older-message progress inside the transcript")
        waitForOlderToFinish(older)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        scrollToOlder(table, indicator: older)
        XCTAssertTrue(older.exists, "The scroller can fetch older pages during latest validation")
        XCTAssertTrue(title.exists)
        capture("Independent older paging during latest refresh")
        waitForOlderToFinish(older)
        XCTAssertTrue(title.exists, "The older page finished without waiting for the latest page")
        XCTAssertTrue(table.exists)
        XCTAssertTrue(title.waitForNonExistence(timeout: 30))
        app.terminate()
    }

    private func scrollToOlder(_ table: XCUIElement, indicator: XCUIElement) {
        for _ in 0..<6 {
            if indicator.exists { return }
            table.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(indicator.waitForExistence(timeout: 5), table.debugDescription)
    }

    private func waitForOlderToFinish(_ indicator: XCUIElement) {
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 15))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
