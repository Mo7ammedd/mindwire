#if DEBUG
import UIKit
import XCTest

final class SourceControlTreeInteractionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    func testCleanPushActionAndGitHubAccessRecovery() {
        let clean = launch(suite: UUID().uuidString, accessFixture: "push")
        XCTAssertTrue(clean.buttons["git.clean.push"].isHittable)
        XCTAssertTrue(clean.staticTexts["Ready to push"].exists)
        capture("Clean repository with local commits ready to push")
        clean.terminate()

        let app = launch(suite: UUID().uuidString, theme: "light", accessFixture: "auth")
        app.buttons["git.openCommit"].tap()
        let message = app.descendants(matching: .any)["git.commit.message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.tap()
        message.typeText("Keep this draft")
        app.buttons["git.commit.submit"].tap()
        XCTAssertTrue(app.buttons["git.authentication.recover"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((message.value as? String)?.contains("Keep this draft") == true)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Access recovery stays inside the commit form")
        let detail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "terminal prompts disabled")).firstMatch
        XCTAssertFalse(detail.exists, "The terminal diagnostic starts collapsed")
        capture("GitHub access recovery preserves the commit draft")
        app.buttons["GitHub access required"].tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        app.terminate()
    }

    func testTreeGroupsChangesAndOpensTheExistingDiff() {
        let suite = UUID().uuidString
        var app = launch(suite: suite)
        chooseLayout("Tree", app: app)
        let source = app.buttons["git.folder.working.src"]
        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        let component = app.buttons["git.folder.working.src/components"]
        let change = file("working", "src/components/Dashboard.tsx", app: app)
        XCTAssertTrue(change.exists)
        component.tap()
        XCTAssertTrue(change.waitForNonExistence(timeout: 5))
        XCTAssertEqual(component.value as? String, "Collapsed")
        component.tap()
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        capture("Changed files grouped with the explorer tree layout")
        let compact = app.buttons["git.folder.staged.src"]
        XCTAssertTrue(compact.label.contains("src › styles"), "Single-folder chains are compact by default")
        app.buttons["git.repository.actions"].tap()
        app.buttons["Customize Tree"].tap()
        let compactToggle = app.switches["files.tree.compact"]
        XCTAssertTrue(compactToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(compactToggle.value as? String, "1")
        app.sliders["files.tree.horizontal"].adjust(toNormalizedSliderPosition: 0.7)
        app.sliders["files.tree.vertical"].adjust(toNormalizedSliderPosition: 0.35)
        let nativeSwitch = compactToggle.switches.firstMatch
        if nativeSwitch.exists { nativeSwitch.tap() }
        else { compactToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertEqual(compactToggle.value as? String, "0")
        capture("Shared tree customization with a live preview")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["git.folder.staged.src/styles"].waitForExistence(timeout: 5))
        XCTAssertTrue(file("staged", "src/styles/theme.css", app: app).exists,
                      "Changing presentation keeps the same file and diff actions")
        chooseLayout("List", app: app)
        XCTAssertFalse(source.exists)
        XCTAssertTrue(change.exists)
        chooseLayout("Tree", app: app)
        XCUIDevice.shared.press(.home)
        app.terminate()
        app = launch(suite: suite)
        XCTAssertTrue(app.buttons["git.folder.working.src"].waitForExistence(timeout: 5),
                      "Source Control must remember its own layout preference")
        XCTAssertTrue(app.buttons["git.folder.staged.src/styles"].exists,
                      "Compact-folder preference must survive relaunch")
        app.buttons["git.repository.actions"].tap()
        app.buttons["Customize Tree"].tap()
        let reset = app.buttons["files.tree.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        let resetApplied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"),
                                                    object: app.switches["files.tree.compact"])
        XCTAssertEqual(XCTWaiter.wait(for: [resetApplied], timeout: 3), .completed)
        capture("Compact folders and default spacing preview")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["git.folder.staged.src"].label.contains("src › styles"))
        file("working", "src/components/Dashboard.tsx", app: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["git.diff.editor"].firstMatch.waitForExistence(timeout: 10),
                      "A tree leaf opens the existing diff rather than a regular file editor")
        capture("Tree change opened in the existing diff viewer")
        app.terminate()
    }

    func testTreeKeepsStagingAndUnstagingInline() {
        let app = launch(suite: UUID().uuidString, theme: "light")
        chooseLayout("Tree", app: app)
        let path = "src/components/Dashboard.tsx"
        let working = file("working", path, app: app)
        XCTAssertTrue(working.waitForExistence(timeout: 5))
        working.swipeLeft()
        capture("Compact text-only file swipe actions")
        app.buttons["Stage"].firstMatch.tap()
        let staged = file("staged", path, app: app)
        XCTAssertTrue(staged.waitForExistence(timeout: 10), "Staging moves the file into its staged tree")
        XCTAssertTrue(working.waitForNonExistence(timeout: 5))
        capture("Staged change in its folder with the working tree still visible")
        staged.swipeLeft()
        app.buttons["Unstage"].firstMatch.tap()
        XCTAssertTrue(working.waitForExistence(timeout: 10))
        XCTAssertTrue(staged.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.terminate()
    }

    func testStickyFolderPathFollowsVisibleChanges() {
        let app = launch(suite: UUID().uuidString, scrollFixture: true)
        chooseLayout("Tree", app: app)
        let breadcrumb = app.descendants(matching: .any)["git.breadcrumb.working"].firstMatch
        let list = app.collectionViews.firstMatch
        let metrics = app.otherElements["git.scroll.metrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 5))
        func counters() -> [String: Int] {
            Dictionary(uniqueKeysWithValues: (metrics.value as? String ?? "").split(separator: ";").compactMap {
                let pair = $0.split(separator: "=")
                guard pair.count == 2, let value = Int(pair[1]) else { return nil }
                return (String(pair[0]), value)
            })
        }
        let before = counters()
        XCTAssertLessThan(before["rows"] ?? .max, 200,
                          "The prepared tree must create visible rows, not evaluate all 1,098 files up front")
        capture("Compact repository overview with native context bar")
        func shortDrag(upward: Bool) {
            let start = counters()
            let origin = list.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.72))
            let target = list.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: upward ? 0.60 : 0.84))
            origin.press(forDuration: 0.01, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.15)
            let end = counters()
            let distance = ((end["offset"] ?? 0) - (start["offset"] ?? 0)) * (upward ? 1 : -1)
            XCTAssertGreaterThan(distance, 25, "A short drag must move the list in the finger's direction")
            XCTAssertEqual(end["inset"], before["inset"], "Changing context must never insert or remove a scroll inset")
        }
        // Start with cold, short gestures across the overview/context boundary;
        // the native bar must retain exactly the same space throughout.
        for _ in 0..<4 { shortDrag(upward: true) }
        func seek(_ folder: String, upward: Bool = true) {
            for _ in 0..<8 {
                if breadcrumb.exists, breadcrumb.value as? String == folder { return }
                if upward { list.swipeUp(velocity: .slow) }
                else { list.swipeDown(velocity: .slow) }
            }
            XCTAssertEqual(breadcrumb.value as? String, folder, app.debugDescription)
        }
        seek("apps/api/features/workspace/source-control/components/breadcrumbs")
        let pathScroller = app.scrollViews["git.breadcrumb.scroll.working"]
        XCTAssertTrue(pathScroller.exists)
        XCTAssertGreaterThan(pathScroller.frame.width, list.frame.width * 0.85, "The path gets the whole header width")
        capture("Long breadcrumb reveals the current folder")
        let verticalOffset = counters()["offset"] ?? 0
        pathScroller.swipeRight(velocity: .slow)
        XCTAssertLessThanOrEqual(abs((counters()["offset"] ?? 0) - verticalOffset), 1,
                                "Scrolling parent folders must not move the outer file list")
        capture("Long breadcrumb scrolls back to its parents")
        seek("apps/api/modules")
        let pinnedY = breadcrumb.frame.minY
        let navigationMenu = app.buttons["git.repository.actions"]
        XCTAssertTrue(navigationMenu.isHittable, "Native navigation stays reachable inside the rounded modal")
        XCTAssertGreaterThan(breadcrumb.frame.minY, navigationMenu.frame.maxY + 4,
                             "The sticky path must remain below the native navigation inset")
        capture("Sticky breadcrumb for nested API files")
        shortDrag(upward: true)
        shortDrag(upward: false)
        seek("apps/api/routes")
        XCTAssertEqual(breadcrumb.frame.minY, pinnedY, accuracy: 1, "Changing paths must not move the pinned header")
        capture("Sticky breadcrumb follows the next folder")
        seek("apps/api/modules", upward: false)
        XCTAssertTrue(app.buttons["git.repository.actions"].isHittable)
        XCTAssertEqual(breadcrumb.frame.minY, pinnedY, accuracy: 1, "Reversing direction must not jump the header")
        XCTAssertTrue(app.buttons["Stage All"].firstMatch.exists)
        let after = counters()
        XCTAssertEqual(after["bodies"], before["bodies"], "Path updates must not reevaluate the tree views")
        XCTAssertEqual(after["builds"], before["builds"], "Scrolling must reuse the prepared trees")
        XCTAssertLessThan(after["visible"] ?? .max, 80, "Tracking must be bounded by the viewport")
        XCTAssertEqual(after["inset"], before["inset"], "The permanent native context bar leaves scroll insets fixed throughout")
        let performance = XCTAttachment(string: "Before scrolling: \(before)\nAfter scrolling: \(after)")
        performance.name = "Breadcrumb scroll work"
        performance.lifetime = .keepAlways
        add(performance)
        let prepared = app.buttons["git.folder.staged.prepared"]
        for _ in 0..<8 {
            if prepared.exists, prepared.isHittable { break }
            list.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(prepared.isHittable)
        let preparedFile = file("staged", "prepared/config0.json", app: app)
        XCTAssertTrue(preparedFile.exists)
        prepared.tap()
        XCTAssertTrue(preparedFile.waitForNonExistence(timeout: 3), "Flattened rows must still collapse with their folder")
        prepared.tap()
        XCTAssertTrue(preparedFile.waitForExistence(timeout: 3), "Reopening restores the same children")
        app.terminate()
    }

    func testPullRequestShowsCommittedDiffAndLocalStagedFiles() {
        let app = launch(suite: UUID().uuidString, theme: "light", pullRequestFixture: true)
        app.buttons["git.openPullRequest"].tap()
        let review = app.buttons["git.pr.reviewFiles"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["git.pr.create"].label.contains("Push"), "Use the fresh remote tip, not the cached tracking ref")
        XCTAssertTrue(file("staged", "src/styles/theme.css", app: app).exists, "Staged files are visible separately from committed PR changes")
        capture("Pull request comparison and separate staged files")
        review.tap()
        let changes = app.collectionViews["git.pr.files"]
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        let committed = changes.descendants(matching: .any)["git.file.staged.src/components/Dashboard.tsx"].firstMatch
        XCTAssertTrue(committed.waitForExistence(timeout: 5))
        XCTAssertFalse(changes.descendants(matching: .any)["git.file.staged.src/styles/theme.css"].exists,
                       "Uncommitted files must not leak into the PR comparison")
        capture("Committed pull request files")
        committed.tap()
        XCTAssertTrue(app.descendants(matching: .any)["git.diff.editor"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["git.diff.stage"].exists, "The committed comparison must be read-only")
        capture("Pull request file opens in the shared diff viewer")
        app.terminate()
    }

    private func launch(suite: String, theme: String = "dark", scrollFixture: Bool = false,
                        pullRequestFixture: Bool = false, accessFixture: String? = nil) -> XCUIApplication {
        // A physical device may present this over the app during a long validation session.
        // Close only the battery notice; do not change the phone's power settings.
        addUIInterruptionMonitor(withDescription: "Low battery notice") { alert in
            guard alert.staticTexts["Low Battery"].exists, alert.buttons["Close"].exists else { return false }
            alert.buttons["Close"].tap()
            return true
        }
        let batteryAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["Low Battery"]
        if batteryAlert.exists, batteryAlert.buttons["Close"].exists { batteryAlert.buttons["Close"].tap() }
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "source", "MINDWIRE_STORE_THEME": theme,
                                 "MINDWIRE_LIBRARY_TEST_SUITE": suite, "MINDWIRE_GIT_MODAL_FIXTURE": "1"]
        if scrollFixture { app.launchEnvironment["MINDWIRE_GIT_SCROLL_FIXTURE"] = "1" }
        if pullRequestFixture { app.launchEnvironment["MINDWIRE_GIT_PR_FIXTURE"] = "1" }
        if let accessFixture { app.launchEnvironment["MINDWIRE_GIT_ACCESS_FIXTURE"] = accessFixture }
        app.launch()
        let ready = accessFixture == "push" ? "git.clean.push" : "git.fileLayout"
        XCTAssertTrue(app.buttons[ready].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }

    private func chooseLayout(_ name: String, app: XCUIApplication) {
        app.buttons["git.fileLayout"].tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
    }

    private func file(_ group: String, _ path: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["git.file.\(group).\(path)"].firstMatch
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
