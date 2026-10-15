import XCTest
import UIKit

final class AppStoreScreenshots: XCTestCase {
    func testCaptureAppStoreScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MINDWIRE_STORE_CAPTURE_DIR"] != nil || environment["MINDWIRE_STORE_CAPTURE"] == "1" else {
            throw XCTSkip("Opt in using scripts/app-store/capture.py.")
        }
        // A physical phone exports through XCTest attachments; its temporary directory
        // stays inside the test runner's sandbox instead of using a Mac filesystem path.
        let output = environment["MINDWIRE_STORE_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MindwireScreenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let tablet = ProcessInfo.processInfo.environment["MINDWIRE_STORE_DEVICE"] == "ipad"
        let expectedWidth = Int(environment["MINDWIRE_STORE_PIXEL_WIDTH"] ?? "") ?? (tablet ? 2_752 : 1_320)
        let expectedHeight = Int(environment["MINDWIRE_STORE_PIXEL_HEIGHT"] ?? "") ?? (tablet ? 2_064 : 2_868)
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        continueAfterFailure = false
        let themes = (ProcessInfo.processInfo.environment["MINDWIRE_STORE_THEMES"] ?? "dark,light").split(separator: ",").map(String.init)
        let selected = ProcessInfo.processInfo.environment["MINDWIRE_STORE_SCENES"]?.split(separator: ",").map(String.init)
        for theme in themes {
            for (number, scene) in [(1, "chat"), (2, "projects"), (3, "review"), (4, "files"), (5, "desktop"), (6, "switch"),
                                    (7, "workspaces"), (8, "agents")]
            where selected?.contains(scene) ?? (number <= 6) {
                app.launchArguments = ["--app-store-preview"]
                app.launchEnvironment = ["MINDWIRE_STORE_SCENE": scene, "MINDWIRE_STORE_THEME": theme]
                app.launch()
                XCTAssertTrue(app.otherElements["store.ready"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
                if scene == "review" {
                    XCTAssertTrue(app.descendants(matching: .any)["git.diff.editor"].firstMatch.waitForExistence(timeout: 10))
                } else if scene == "files" {
                    XCTAssertTrue(app.descendants(matching: .any)["file.editor"].firstMatch.waitForExistence(timeout: 10))
                } else if scene == "desktop" {
                    XCTAssertTrue(app.buttons["Release"].firstMatch.waitForExistence(timeout: 15))
                } else if scene == "switch" {
                    let workspace = app.buttons["project.transfer.workspace"]
                    XCTAssertTrue(workspace.waitForExistence(timeout: 10))
                    workspace.tap()
                    let target = app.staticTexts["Cloud Studio"].firstMatch
                    XCTAssertTrue(target.waitForExistence(timeout: 10))
                    target.tap()
                    let ready = NSPredicate(format: "exists == true AND enabled == true")
                    expectation(for: ready, evaluatedWith: app.buttons["project.transfer.start"])
                    waitForExpectations(timeout: 10)
                }
                // Syntax parsing and the native glass transitions finish after the controls
                // become accessible. Let the rendered screen settle before exporting pixels.
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                let name = String(format: "%02d-%@-%@", number, scene, theme)
                let screenshot = XCUIScreen.main.screenshot()
                // Bake orientation into the pixels; App Store Connect must not depend on EXIF.
                let source = screenshot.image
                let upright = UIGraphicsImageRenderer(size: source.size, format: source.imageRendererFormat).image { _ in
                    source.draw(at: .zero)
                }
                let expected = CGSize(width: expectedWidth, height: expectedHeight)
                XCTAssertEqual(CGSize(width: upright.cgImage!.width, height: upright.cgImage!.height), expected)
                try XCTUnwrap(upright.pngData()).write(to: output.appendingPathComponent(name + ".png"))
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                app.terminate()
            }
        }
    }
}
