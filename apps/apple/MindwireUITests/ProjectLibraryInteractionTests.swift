#if DEBUG
import UIKit
import XCTest

/// The real library UI, backed by offline projects. Run on both iPhone and iPad.
final class ProjectLibraryInteractionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    func testProjectCardPushesOnceInListAndGridAfterRecencyChanges() {
        let app = launch(suite: UUID().uuidString, navigationProbe: true)
        for layout in ["List", "Grid"] {
            choosePreference(layout, app: app)
            for index in [4, 0, 4] {
                let row = projectRow(app, index)
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                row.tap()
                assertNavigationDepth(1, app: app)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    XCTAssertTrue(app.otherElements["navigation.sidebar"].exists)
                } else {
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                    assertNavigationDepth(0, app: app)
                    XCTAssertTrue(projectRow(app, index).isHittable, "One Back must return to the project list")
                }
            }
        }
        app.terminate()
    }

    func testFolderProjectPushesOnceAndBackKeepsTheFolder() {
        let app = launch(suite: UUID().uuidString, navigationProbe: true)
        createFolder("Work", app: app)
        app.buttons["projectFolder.member.store-project-0"].tap()
        app.buttons["projectFolder.member.store-project-1"].tap()
        app.buttons["projectFolder.saveMembers"].tap()
        folderRow(app, name: "Work").tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 5))
        let depth = app.descendants(matching: .any)["library.navigationDepth"].firstMatch
        let base = Int(depth.value as? String ?? "") ?? 0
        for layout in ["List", "Grid"] {
            choosePreference(layout, app: app)
            for index in [1, 0] {
                projectRow(app, index).tap()
                assertNavigationDepth(UIDevice.current.userInterfaceIdiom == .pad ? 1 : base + 1, app: app)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    XCTAssertTrue(app.navigationBars["Work"].exists)
                } else {
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                    assertNavigationDepth(base, app: app)
                    XCTAssertTrue(app.navigationBars["Work"].exists, "Back must return to the same folder")
                    XCTAssertTrue(projectRow(app, index).isHittable)
                }
            }
        }
        app.terminate()
    }

    private func assertNavigationDepth(_ count: Int, app: XCUIApplication) {
        let depth = app.descendants(matching: .any)["library.navigationDepth"].firstMatch
        let matches = NSPredicate { _, _ in depth.exists && depth.value as? String == String(count) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: nil)], timeout: 5), .completed,
                       "A card tap must add exactly one destination: \(app.debugDescription)")
    }

    func testFolderAndChatNavigationSurviveBackgroundTermination() {
        let suite = UUID().uuidString
        var app = launch(suite: suite, navigationProbe: true, restoration: true)
        createFolder("Work", app: app)
        app.buttons["projectFolder.member.store-project-0"].tap()
        app.buttons["projectFolder.saveMembers"].tap()
        folderRow(app, name: "Work").tap()
        projectRow(app, 0).tap()
        let title = "Build a beautiful dashboard"
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts[title].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer"].firstMatch.waitForExistence(timeout: 5))
        let expectedDepth = UIDevice.current.userInterfaceIdiom == .pad ? 2 : 3
        assertNavigationDepth(expectedDepth, app: app)

        XCUIDevice.shared.press(.home)
        app.terminate()
        app = launch(suite: suite, navigationProbe: true, restoration: true, expectRoot: false)
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer"].firstMatch.waitForExistence(timeout: 10),
                      "A cold launch must return to the open conversation")
        assertNavigationDepth(expectedDepth, app: app)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.navigationBars["Work"].exists, "The containing folder must also return in the sidebar")
        }
        capture("Conversation and folder restored after process termination")
        let detail = app.otherElements["navigation.detail"]
        detail.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["New chat"].firstMatch.waitForExistence(timeout: 5))
        assertNavigationDepth(expectedDepth - 1, app: app)
        if UIDevice.current.userInterfaceIdiom != .pad {
            detail.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 5))
        }
        XCUIDevice.shared.press(.home)
        app.terminate()
        app = launch(suite: suite, navigationProbe: true, restoration: true, expectRoot: false)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["chat.composer"].firstMatch.exists,
                       "A conversation popped before termination must not come back")
        capture("Back navigation remains correct after a second cold launch")
        app.terminate()
    }

    func testSelectedTabAndOtherTabHistorySurviveTermination() {
        let suite = UUID().uuidString
        var app = launch(suite: suite, navigationProbe: true, restoration: true)
        projectRow(app, 0).tap()
        assertNavigationDepth(1, app: app)
        selectTab("Settings", app: app)
        let backup = app.staticTexts["Backup & Sync"].firstMatch
        if !backup.isHittable { app.swipeUp() }
        XCTAssertTrue(backup.waitForExistence(timeout: 5))
        backup.tap()
        XCTAssertTrue(app.switches["backup.icloud-toggle"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.terminate()
        app = launch(suite: suite, navigationProbe: true, restoration: true, expectRoot: false)
        XCTAssertTrue(app.switches["backup.icloud-toggle"].waitForExistence(timeout: 10),
                      "The selected Settings tab and pushed screen must both return")
        capture("Settings destination restored after process termination")
        selectTab("Projects", app: app)
        XCTAssertTrue(app.staticTexts["New chat"].firstMatch.waitForExistence(timeout: 5))
        assertNavigationDepth(1, app: app)
        app.terminate()
    }

    private func selectTab(_ title: String, app: XCUIApplication) {
        let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), app.debugDescription)
        tab.tap()
    }

    func testRunningAgentArtworkAndRingInListAndGrid() {
        let suite = UUID().uuidString
        for theme in ["dark", "light"] {
            let app = launch(suite: suite, theme: theme, running: true)
            for index in [0, 2] {
                let row = projectRow(app, index)
                XCTAssertTrue(row.label.contains("Agent working in this project"), app.debugDescription)
            }
            capture("Running project agent rings in \(theme) list")
            choosePreference("Grid", app: app)
            capture("Running project agent rings in \(theme) grid")
            choosePreference("List", app: app)
            app.terminate()
        }
    }

    func testCreatePopulateRenameMoveAndDeleteFolderKeepsProjects() {
        let suite = UUID().uuidString
        var app = launch(suite: suite, theme: "light")
        chooseAction("newFolder", app: app)
        // UIAlertController exposes its native text field by placeholder, not SwiftUI's ID.
        var name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Client Work")
        app.buttons["projectFolder.saveName"].firstMatch.tap()

        let first = app.buttons["projectFolder.member.store-project-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        first.tap()
        app.buttons["projectFolder.member.store-project-1"].tap()
        app.buttons["projectFolder.saveMembers"].tap()
        var folder = folderRow(app, name: "Client Work")
        XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(projectRow(app, 0).exists, "Folder mode removes grouped projects from the root list")
        capture("Library with folder and ungrouped projects")

        choosePreference("All Projects", app: app)
        XCTAssertTrue(projectRow(app, 0).waitForExistence(timeout: 5))
        XCTAssertTrue(projectRow(app, 1).exists)
        XCTAssertFalse(folder.exists, "All Projects includes grouped projects in one flat list")
        choosePreference("Folders", app: app)
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        app.terminate()
        app = launch(suite: suite, theme: "light", grouped: true)
        name = app.alerts.textFields.firstMatch
        folder = folderRow(app, name: "Client Work")
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "Folders and the selected view survive relaunch")
        XCTAssertFalse(projectRow(app, 0).exists)
        folder.tap()
        XCTAssertTrue(projectRow(app, 0).waitForExistence(timeout: 5))
        XCTAssertTrue(projectRow(app, 1).exists)

        chooseAction("renameFolder", app: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Client Work".count) + "Clients")
        app.buttons["projectFolder.saveName"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Clients"].waitForExistence(timeout: 5))

        projectRow(app, 0).press(forDuration: 0.8)
        let move = app.buttons["Move to Folder"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.tap()
        let noFolder = app.buttons["projectFolder.move.none"]
        XCTAssertTrue(noFolder.waitForExistence(timeout: 5))
        noFolder.tap()
        XCTAssertFalse(projectRow(app, 0).waitForExistence(timeout: 1))
        XCTAssertTrue(projectRow(app, 1).exists)

        chooseAction("deleteFolder", app: app)
        let confirm = app.buttons["projectFolder.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(projectRow(app, 0).waitForExistence(timeout: 5))
        XCTAssertTrue(projectRow(app, 1).exists)
        XCTAssertFalse(folderRow(app, name: "Clients").exists)
        capture("Projects retained after deleting their library folder")
        app.terminate()
    }

    func testHoldingCardReordersDirectlyAndCustomOrderPersists() {
        let suite = UUID().uuidString
        let app = launch(suite: suite)
        capture("Project cards before a direct hold and drag")
        dragInlineProject(4, before: 0, app: app)
        XCTAssertFalse(app.buttons["projects.finishReordering"].exists)
        XCTAssertTrue(app.buttons["projects.options"].exists, "Dragging does not enter an editing mode")
        XCTAssertLessThan(projectRow(app, 4).frame.midY, projectRow(app, 0).frame.midY,
                          "Native dragging must reorder on the Projects screen")
        capture("Projects reordered inline in the list")
        app.terminate()

        let reopened = launch(suite: suite)
        XCTAssertLessThan(projectRow(reopened, 4).frame.midY, projectRow(reopened, 0).frame.midY,
                          "The custom order must be restored on a fresh launch")
        capture("Custom project order restored")
        reopened.terminate()
    }

    func testProjectActionsDoNotOfferAnExtraReorderMode() {
        let app = launch(suite: UUID().uuidString)
        projectRow(app, 0).press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Move to Folder"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Reorder"].exists)
        capture("Project context menu with the card-shaped preview")
        dismissContextMenu("Move to Folder", app: app)
        openOptions(app)
        XCTAssertFalse(app.buttons["projects.options.reorder"].exists)
        XCTAssertTrue(app.buttons["projects.options.newProject"].exists)
        capture("Project options without a redundant reorder mode")
        app.terminate()
    }

    func testGridLayoutUsesNativeDragAndKeepsOrderWhenSwitchingToList() {
        let suite = UUID().uuidString
        let app = launch(suite: suite, theme: "light")
        choosePreference("Grid", app: app)
        XCTAssertTrue(app.scrollViews["projects.grid"].waitForExistence(timeout: 5), app.debugDescription)
        capture("Project grid in light appearance")
        let source = projectRow(app, 4).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = projectRow(app, 0).coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
        source.press(forDuration: 0.6, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 1)
        let moved = NSPredicate { _, _ in
            let first = self.projectRow(app, 4).frame
            let second = self.projectRow(app, 0).frame
            // Adjacent cards share a row after a successful move in the grid.
            return first.midY < second.midY - 1
                || (abs(first.midY - second.midY) <= 1 && first.midX < second.midX)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: app)], timeout: 5), .completed,
                       app.debugDescription)
        capture("Project grid reordered inline")
        XCTAssertFalse(app.buttons["projects.finishReordering"].exists)
        choosePreference("List", app: app)
        XCTAssertLessThan(projectRow(app, 4).frame.midY, projectRow(app, 0).frame.midY)
        choosePreference("Grid", app: app)
        app.terminate()
        let reopened = launch(suite: suite, theme: "dark")
        XCTAssertTrue(reopened.scrollViews["projects.grid"].waitForExistence(timeout: 5))
        capture("Project grid preference restored in dark appearance")
        reopened.terminate()
    }

    func testFolderPickerExcludesProjectsAlreadyInAnotherFolder() {
        // iOS 26 context menus can add two 60-second XCTest quiescence waits.
        // Leave time for the second drag and the final folder navigation assertions.
        executionTimeAllowance = 360
        let app = launch(suite: UUID().uuidString, theme: "light")
        createFolder("Work", app: app)
        app.buttons["projectFolder.member.store-project-0"].tap()
        app.buttons["projectFolder.member.store-project-1"].tap()
        app.buttons["projectFolder.saveMembers"].tap()
        XCTAssertTrue(folderRow(app, name: "Work").waitForExistence(timeout: 5))

        createFolder("Personal", app: app)
        XCTAssertTrue(app.buttons["projectFolder.member.store-project-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["projectFolder.member.store-project-0"].exists)
        XCTAssertFalse(app.buttons["projectFolder.member.store-project-1"].exists)
        capture("New folder offers only unassigned projects")
        app.buttons["projectFolder.member.store-project-2"].tap()
        app.buttons["projectFolder.saveMembers"].tap()
        let workList = folderRow(app, name: "Work")
        let personalList = folderRow(app, name: "Personal")
        XCTAssertTrue(personalList.waitForExistence(timeout: 5))
        dragCard(personalList, before: workList)
        XCTAssertLessThan(personalList.frame.midY, workList.frame.midY,
                          "Folders drag directly in the list without editing")
        personalList.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Rename Folder"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Reorder"].exists)
        capture("Folder context menu with only folder actions")
        dismissContextMenu("Rename Folder", app: app)
        dragCard(workList, before: personalList)
        XCTAssertLessThan(workList.frame.midY, personalList.frame.midY,
                          "Dragging also works after dismissing a folder context menu")
        choosePreference("Grid", app: app)
        let work = folderRow(app, name: "Work")
        let personal = folderRow(app, name: "Personal")
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        XCTAssertTrue(personal.exists)
        capture("Folders with project previews in the grid")
        personal.press(forDuration: 0.7, thenDragTo: work)
        choosePreference("List", app: app)
        XCTAssertLessThan(folderRow(app, name: "Personal").frame.midY, folderRow(app, name: "Work").frame.midY)
        folderRow(app, name: "Work").tap()
        chooseAction("chooseProjects", app: app)
        XCTAssertTrue(app.buttons["projectFolder.member.store-project-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projectFolder.member.store-project-1"].exists)
        XCTAssertFalse(app.buttons["projectFolder.member.store-project-2"].exists)
        capture("Existing members and available projects stay separate")
        app.buttons["projectFolder.saveMembers"].tap()
        projectRow(app, 0).tap()
        XCTAssertTrue(app.navigationBars["Orbit"].waitForExistence(timeout: 5))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.navigationBars["Work"].exists, "A folder stays in the sidebar when a project opens")
            XCTAssertTrue(projectRow(app, 1).exists, "The rest of the folder stays available beside the project")
            capture("Folder sidebar with its project open on iPad")
        }
        app.terminate()
    }

    func testOptionsSheetStartsNewProjectAndDismissesBeforeFolderActions() {
        let suite = UUID().uuidString
        var app = launch(suite: suite, theme: "light")
        XCTAssertEqual(app.buttons.matching(identifier: "projects.options").count, 1)
        XCTAssertFalse(app.buttons["projects.add"].exists, "Creation and preferences share one toolbar button")
        openOptions(app)
        let newProject = app.buttons["projects.options.newProject"]
        XCTAssertLessThan(newProject.frame.minY, app.buttons["projects.options.newFolder"].frame.minY)
        capture("Projects options sheet in light appearance")
        newProject.tap()
        XCTAssertTrue(app.navigationBars["New project"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(newProject.exists, "The options sheet dismisses before project creation opens")
        app.navigationBars["New project"].buttons["Cancel"].tap()
        XCTAssertTrue(projectRow(app, 0).waitForExistence(timeout: 5))

        createFolder("Design", app: app)
        for index in 0..<4 { app.buttons["projectFolder.member.store-project-\(index)"].tap() }
        app.buttons["projectFolder.saveMembers"].tap()
        XCTAssertTrue(folderRow(app, name: "Design").waitForExistence(timeout: 5))
        XCTAssertTrue(projectRow(app, 4).exists)
        capture("Folder card with four custom project icons")
        choosePreference("Grid", app: app)
        capture("Folder grid with four custom project icons")

        createFolder("Tools", app: app)
        app.buttons["projectFolder.member.store-project-4"].tap()
        app.buttons["projectFolder.saveMembers"].tap()
        XCTAssertTrue(folderRow(app, name: "Tools").waitForExistence(timeout: 5))
        capture("Folder preview without custom project icons")
        app.terminate()
        app = launch(suite: suite, theme: "dark", grouped: true)
        XCTAssertTrue(app.scrollViews["projects.grid"].waitForExistence(timeout: 5))
        capture("Folder grid with custom and default artwork in dark appearance")
        choosePreference("List", app: app)
        capture("Folder list with custom and default artwork in dark appearance")
        openOptions(app)
        capture("Projects options sheet in dark appearance")
        app.buttons["projects.options.done"].tap()
        folderRow(app, name: "Design").tap()
        openOptions(app)
        capture("Folder options sheet")
        XCTAssertFalse(app.buttons["projects.options.newFolder"].exists)
        XCTAssertTrue(app.buttons["projects.options.chooseProjects"].exists)
        XCTAssertTrue(app.buttons["projects.options.renameFolder"].exists)
        XCTAssertTrue(app.buttons["projects.options.deleteFolder"].exists)
        XCTAssertTrue(app.buttons["projects.options.deleteFolder"].isHittable,
                      "All folder actions fit at the sheet's initial height")
        app.terminate()
    }

    func testEmptyFolderOffersCreationWhenAllProjectsAreOrganized() {
        let suite = UUID().uuidString
        var app = launch(suite: suite, theme: "light")
        createFolder("Work", app: app)
        capture("Choose Projects with card-sized project artwork")
        for index in 0..<5 { app.buttons["projectFolder.member.store-project-\(index)"].tap() }
        app.buttons["projectFolder.saveMembers"].tap()
        XCTAssertTrue(folderRow(app, name: "Work").waitForExistence(timeout: 5))

        createFolder("Ideas", app: app)
        let create = app.buttons["projectFolder.createProject"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["All projects are organized"].exists)
        XCTAssertFalse(app.buttons["projectFolder.member.store-project-0"].exists)
        XCTAssertFalse(app.buttons["projectFolder.saveMembers"].exists)
        XCTAssertEqual(app.searchFields.count, 0, "An empty picker does not need an inactive search field")
        capture("All projects organized with Create Project in light appearance")
        create.tap()
        assertCreation(in: "Ideas", app: app)
        XCTAssertFalse(app.navigationBars["Choose Projects"].exists, "The picker closes before creation opens")
        app.navigationBars["New project"].buttons["Cancel"].tap()
        XCTAssertTrue(folderRow(app, name: "Ideas").waitForExistence(timeout: 5))

        for theme in ["light", "dark"] {
            if theme == "dark" {
                app.terminate()
                app = launch(suite: suite, theme: theme, grouped: true)
            }
            folderRow(app, name: "Ideas").tap()
            let directCreate = app.buttons["projects.newProject"]
            XCTAssertTrue(directCreate.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["projectFolder.chooseProjects"].exists,
                           "When nothing is available, the empty folder offers creation directly")
            capture("Empty folder with direct creation in \(theme) appearance")
            directCreate.tap()
            assertCreation(in: "Ideas", app: app)
            app.navigationBars["New project"].buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["Ideas"].waitForExistence(timeout: 5))
            chooseAction("chooseProjects", app: app)
            let pickerCreate = app.buttons["projectFolder.createProject"]
            XCTAssertTrue(pickerCreate.waitForExistence(timeout: 5))
            capture("Empty Choose Projects sheet in \(theme) appearance")
            pickerCreate.tap()
            assertCreation(in: "Ideas", app: app)
            app.navigationBars["New project"].buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["Ideas"].waitForExistence(timeout: 5))
        }
        app.terminate()
    }

    func testEmptyFolderCanChooseExistingProjectsOrCreateOne() {
        let app = launch(suite: UUID().uuidString, theme: "dark")
        createFolder("Ideas", app: app)
        app.navigationBars["Choose Projects"].buttons["Cancel"].tap()
        folderRow(app, name: "Ideas").tap()
        let choose = app.buttons["projectFolder.chooseProjects"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projects.newProject"].exists)
        capture("Empty folder with existing projects available")
        app.buttons["projects.newProject"].tap()
        assertCreation(in: "Ideas", app: app)
        app.navigationBars["New project"].buttons["Cancel"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
        let member = app.buttons["projectFolder.member.store-project-0"]
        XCTAssertTrue(member.waitForExistence(timeout: 5))
        member.tap()
        app.buttons["projectFolder.saveMembers"].tap()
        XCTAssertTrue(projectRow(app, 0).waitForExistence(timeout: 5))
        XCTAssertFalse(choose.exists)
        app.terminate()
    }

    private func assertCreation(in folder: String, app: XCUIApplication) {
        let navigation = app.navigationBars["New project"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(navigation.staticTexts[folder].exists,
                      "Creation must retain the folder that opened it: \(app.debugDescription)")
    }

    private func openOptions(_ app: XCUIApplication) {
        // A real phone can receive a banner over this toolbar while tests run.
        // Wait for it to leave without opening or interacting with its contents.
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .descendants(matching: .any)["NotificationShortLookView"].firstMatch
        XCTAssertTrue(banner.waitForNonExistence(timeout: 15), "A notification is covering the Projects toolbar")
        app.buttons["projects.options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["projects.options.newProject"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func chooseAction(_ action: String, app: XCUIApplication) {
        openOptions(app)
        app.buttons["projects.options.\(action)"].tap()
    }

    private func choosePreference(_ title: String, app: XCUIApplication) {
        openOptions(app)
        let label = ["Grid": "Grid view", "List": "List view"][title] ?? title
        app.buttons[label].firstMatch.tap()
        app.buttons["projects.options.done"].tap()
        XCTAssertTrue(app.buttons["projects.options.done"].waitForNonExistence(timeout: 5))
    }

    private func createFolder(_ name: String, app: XCUIApplication) {
        chooseAction("newFolder", app: app)
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        app.buttons["projectFolder.saveName"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Choose Projects"].waitForExistence(timeout: 5))
    }

    private func dragInlineProject(_ index: Int, before targetIndex: Int, app: XCUIApplication) {
        let source = app.cells.containing(.any, identifier: "project.row.store-project-\(index)").firstMatch
        let target = app.cells.containing(.any, identifier: "project.row.store-project-\(targetIndex)").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(target.exists)
        dragCard(source, before: target)
    }

    private func dismissContextMenu(_ title: String, app: XCUIApplication) {
        // On iPad the menu belongs to the sidebar. Tapping the detail column can leave
        // its lifted preview open, hiding the underlying list's new order.
        let sidebar = app.otherElements["navigation.sidebar"].firstMatch
        let surface = sidebar.exists ? sidebar : app
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(app.buttons[title].firstMatch.waitForNonExistence(timeout: 5))
    }

    private func dragCard(_ source: XCUIElement, before target: XCUIElement) {
        // Drop above the target's midpoint. Dropping at an automatically selected hit point
        // can mean "after this row", which leaves adjacent folders unchanged on iPad.
        let from = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        from.press(forDuration: 0.6, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1)
        let moved = NSPredicate { _, _ in source.frame.midY < target.frame.midY }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: source)], timeout: 5), .completed)
    }

    private func launch(suite: String, theme: String = "dark", grouped: Bool = false, running: Bool = false,
                        navigationProbe: Bool = false, restoration: Bool = false, expectRoot: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--app-store-preview"]
        app.launchEnvironment = ["MINDWIRE_STORE_SCENE": "library", "MINDWIRE_STORE_THEME": theme,
                                 "MINDWIRE_LIBRARY_TEST_SUITE": suite]
        if running { app.launchEnvironment["MINDWIRE_STORE_PROJECT_ACTIVITY"] = "running" }
        if navigationProbe { app.launchEnvironment["MINDWIRE_LIBRARY_NAVIGATION_PROBE"] = "1" }
        if restoration { app.launchEnvironment["MINDWIRE_NAVIGATION_RESTORE"] = "1" }
        app.launch()
        XCTAssertTrue(app.otherElements["store.ready"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        if grouped {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'projectFolder.row.'"))
                .firstMatch.waitForExistence(timeout: 5))
        } else if expectRoot { XCTAssertTrue(projectRow(app, 0).waitForExistence(timeout: 5)) }
        return app
    }

    private func projectRow(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.descendants(matching: .any)["project.row.store-project-\(index)"].firstMatch
    }

    private func folderRow(_ app: XCUIApplication, name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'projectFolder.row.' AND label CONTAINS %@", name)).firstMatch
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
