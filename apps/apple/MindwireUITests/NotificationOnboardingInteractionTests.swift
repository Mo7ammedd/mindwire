#if os(iOS)
import XCTest

@MainActor
final class NotificationOnboardingInteractionTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testFreshInstallExplainsNotificationsAndCanBeDismissed() {
        let app = launch("notification-intro", theme: "dark")
        XCTAssertTrue(app.buttons["notification-intro-sign-in"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["notification-intro-later"].exists)
        XCTAssertTrue(app.staticTexts["Know when your agent needs you"].exists)
        capture("Optional Oblien notification connection — dark")
        app.buttons["notification-intro-cancel"].tap()
        XCTAssertTrue(app.buttons["notification-intro-sign-in"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["store.ready"].firstMatch.exists,
                      "Cancel returns to the phone tabs or the iPad's adaptive navigation")
        app.terminate()
    }

    func testFreshInstallCanDeferTheConnectionWithoutBlockingProjects() {
        let app = launch("notification-intro", theme: "light")
        XCTAssertTrue(app.buttons["notification-intro-later"].waitForExistence(timeout: 15), app.debugDescription)
        capture("Optional Oblien notification connection — light")
        app.buttons["notification-intro-later"].tap()
        XCTAssertTrue(app.buttons["notification-intro-later"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["store.ready"].firstMatch.exists)
        app.terminate()
    }

    func testSettingsDistinguishIOSPermissionFromSignedOutDelivery() {
        let app = launch("notification-settings", theme: "dark")
        XCTAssertTrue(app.buttons["notification-sign-in"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.descendants(matching: .any)["notification-device-permission"].firstMatch.value as? String, "Allowed")
        XCTAssertEqual(app.descendants(matching: .any)["notification-delivery-status"].firstMatch.value as? String, "Sign in required")
        XCTAssertFalse(app.staticTexts["Ready"].exists)
        capture("Notification permission allowed, account connection required")
        app.terminate()
    }

    private func launch(_ scene: String, theme: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": scene, "MINDWIRE_STORE_THEME": theme]
        app.launch()
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
