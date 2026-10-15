import SwiftUI
import XCTest
@testable import Mindwire

@MainActor
final class NavigationRestorationTests: XCTestCase {
    private var suite = ""
    private var stores: Stores!

    override func setUp() {
        super.setUp()
        suite = "navigation-tests-\(UUID().uuidString)"
        stores = Stores(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        stores.defaults.removePersistentDomain(forName: suite)
        stores = nil
        super.tearDown()
    }

    func testFreshProcessRestoresAllTabPathsAndTheIPadFolderFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("navigation.json")
        let app = AppModel(stores: stores)
        let save = NavigationRestoration()
        save.start(app: app, store: .init(url: url), windowID: "window", phase: .active)
        app.projectsPath = NavigationPath([AppRoute.projectFolder(id: "folder", workspaceId: nil),
                                          .projectDetail(id: "project"), .chat(chatId: "chat")])
        app.rememberChatLocation("chat")
        app.agentsPath = NavigationPath([AppRoute.agentDetail(agentId: "agent")])
        app.workspacesPath = NavigationPath([AppRoute.workspaceDetail(id: "workspace"), .workspaceProjects(workspaceId: "workspace")])
        app.settingsPath.append(SettingsRoute.servers)
        app.settingsPath.append(SettingsRoute.serverDetail(id: "computer"))
        app.sidebarPaths[.projects] = NavigationPath([AppRoute.projectFolder(id: "folder", workspaceId: nil)])
        app.hiddenSidebars.insert(.agents)
        app.selectedTab = .settings
        save.phaseChanged(.background)

        let reopened = AppModel(stores: stores)
        let restore = NavigationRestoration()
        restore.start(app: reopened, store: .init(url: url), windowID: "window", phase: .active)
        XCTAssertEqual(reopened.selectedTab, .settings)
        assertPaths(reopened.projectsPath, app.projectsPath)
        assertPaths(reopened.agentsPath, app.agentsPath)
        assertPaths(reopened.workspacesPath, app.workspacesPath)
        assertPaths(reopened.settingsPath, app.settingsPath)
        assertPaths(reopened.sidebarPaths[.projects], app.sidebarPaths[.projects])
        XCTAssertEqual(reopened.hiddenSidebars, [.agents])
        XCTAssertLessThan(try Data(contentsOf: url).count, 8_192, "Navigation only stores small screen identifiers")
        restore.flush()
    }

    func testNavigationChangesCoalesceAndBackgroundFlushesTheLatestLocation() async throws {
        let disk = MemoryDisk()
        let app = AppModel(stores: stores)
        let restoration = NavigationRestoration()
        restoration.start(app: app, store: disk.store(), windowID: "window", phase: .active)
        app.openProject("project")
        app.push(.chat(chatId: "chat"))
        app.rememberChatLocation("chat")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(disk.writes, 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(disk.writes, 1, "Idle navigation has no timer or repeated disk writes")
        app.projectsPath.removeLast()
        restoration.phaseChanged(.inactive)
        XCTAssertEqual(disk.writes, 2, "The pending Back is flushed before suspension")
        restoration.phaseChanged(.background)
        XCTAssertEqual(disk.writes, 2)

        let reopened = AppModel(stores: stores)
        let cold = NavigationRestoration()
        cold.start(app: reopened, store: disk.store(), windowID: "window", phase: .active)
        assertPaths(reopened.projectsPath, NavigationPath([AppRoute.projectDetail(id: "project")]))
        reopened.projectsPath = NavigationPath()
        cold.phaseChanged(.background)
        let root = AppModel(stores: stores)
        let fresh = NavigationRestoration()
        fresh.start(app: root, store: disk.store(), windowID: "window", phase: .active)
        XCTAssertTrue(root.projectsPath.isEmpty, "Returning to the root must replace the previous saved screen")
        fresh.flush()
    }

    func testResumeDoesNotReplayAnOlderSnapshotOverCurrentNavigation() {
        let disk = MemoryDisk()
        let app = AppModel(stores: stores)
        let restoration = NavigationRestoration()
        let store = disk.store()
        restoration.start(app: app, store: store, windowID: "window", phase: .active)
        app.openProject("first")
        restoration.phaseChanged(.background)
        app.openWorkspace("newer")
        restoration.start(app: app, store: store, windowID: "window", phase: .active)
        restoration.phaseChanged(.active)
        XCTAssertEqual(app.selectedTab, .workspaces)
        assertPaths(app.workspacesPath, NavigationPath([AppRoute.workspaceDetail(id: "newer")]))
        restoration.flush()
    }

    func testWindowsStayIndependentAndANewSceneResumesTheLastActiveWindow() {
        let disk = MemoryDisk()
        let store = disk.store()
        let first = AppModel(stores: stores), second = AppModel(stores: stores)
        let one = NavigationRestoration(), two = NavigationRestoration()
        one.start(app: first, store: store, windowID: "first", phase: .active)
        first.openProject("first-project")
        one.phaseChanged(.inactive)
        two.start(app: second, store: store, windowID: "second", phase: .active)
        XCTAssertTrue(second.projectsPath.isEmpty, "A new iPad window must not copy the other window's screen")
        second.openProject("second-project")
        two.flush()
        one.phaseChanged(.background)
        assertPaths(first.projectsPath, NavigationPath([AppRoute.projectDetail(id: "first-project")]))
        assertPaths(second.projectsPath, NavigationPath([AppRoute.projectDetail(id: "second-project")]))

        let coldStore = disk.store()
        let firstAgain = AppModel(stores: stores), secondAgain = AppModel(stores: stores)
        let oneAgain = NavigationRestoration(), twoAgain = NavigationRestoration()
        oneAgain.start(app: firstAgain, store: coldStore, windowID: "first", phase: .active)
        twoAgain.start(app: secondAgain, store: coldStore, windowID: "second", phase: .active)
        assertPaths(firstAgain.projectsPath, first.projectsPath)
        assertPaths(secondAgain.projectsPath, second.projectsPath)

        let newScene = AppModel(stores: stores)
        let fallback = NavigationRestoration()
        fallback.start(app: newScene, store: disk.store(), windowID: "new-scene-after-termination", phase: .active)
        assertPaths(newScene.projectsPath, second.projectsPath, "Backgrounding the older window cannot steal restoration")
        oneAgain.flush(); twoAgain.flush(); fallback.flush()
    }

    func testColdNotificationReusesTheRestoredChatWithoutADuplicatePush() {
        let disk = MemoryDisk()
        let app = AppModel(stores: stores)
        let initial = NavigationRestoration()
        initial.start(app: app, store: disk.store(), windowID: "window", phase: .active)
        app.projectsPath = NavigationPath([AppRoute.projectDetail(id: "project"), .chat(chatId: "chat")])
        app.rememberChatLocation("chat")
        initial.phaseChanged(.background)

        let router = PushRouter()
        router.route(.chat("chat"), notificationID: "cold-notification")
        let reopened = AppModel(stores: stores)
        let restored = NavigationRestoration()
        restored.start(app: reopened, store: disk.store(), windowID: "window", phase: .active)
        // Simulate SwiftUI resolving its lazy restored path before notification delivery.
        reopened.projectsPath = NavigationPath([AppRoute.projectDetail(id: "project"), .chat(chatId: "chat")])
        router.attach(reopened)
        XCTAssertEqual(reopened.selectedTab, .projects)
        assertPaths(reopened.projectsPath, app.projectsPath)
        XCTAssertTrue(reopened.agentsPath.isEmpty)
        router.route(.chat("different"), notificationID: "another-notification")
        restored.phaseChanged(.active)
        XCTAssertEqual(reopened.selectedTab, .agents)
        assertPaths(reopened.agentsPath, NavigationPath([AppRoute.chat(chatId: "different")]))
        restored.flush()
    }

    func testCorruptOrNewerDataFallsBackWithoutStoppingNavigation() throws {
        for data in [Data("not json".utf8), Data(#"{"version":2,"windows":{},"order":[]}"#.utf8)] {
            let disk = MemoryDisk(data: data)
            let app = AppModel(stores: stores)
            let restoration = NavigationRestoration()
            restoration.start(app: app, store: disk.store(), windowID: "window", phase: .active)
            XCTAssertTrue(app.projectsPath.isEmpty)
            XCTAssertEqual(app.selectedTab, .projects)
            app.openProject("works")
            restoration.flush()
            let snapshot = try XCTUnwrap(disk.store().restore(windowID: "window"))
            XCTAssertEqual(snapshot.selectedTab, .projects)
        }
    }

    func testFailedWriteLeavesTheLastGoodSnapshotAndCanRetry() throws {
        let disk = MemoryDisk()
        let store = disk.store()
        let app = AppModel(stores: stores)
        app.openProject("saved")
        XCTAssertTrue(store.save(app.navigationSnapshot, windowID: "window", makeRecent: true))
        let original = disk.data
        disk.failWrites = true
        app.projectsPath = NavigationPath([AppRoute.projectDetail(id: "newer")])
        XCTAssertFalse(store.save(app.navigationSnapshot, windowID: "window", makeRecent: true))
        XCTAssertEqual(disk.data, original)
        disk.failWrites = false
        XCTAssertTrue(store.save(app.navigationSnapshot, windowID: "window", makeRecent: true))
        let reopened = AppModel(stores: stores)
        reopened.restoreNavigation(try XCTUnwrap(disk.store().restore(windowID: "window")))
        assertPaths(reopened.projectsPath, app.projectsPath)
    }

    private func assertPaths(_ left: NavigationPath?, _ right: NavigationPath?, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let left, let right else { return XCTFail("Missing navigation path. " + message, file: file, line: line) }
        XCTAssertTrue(left.hasSameDestinations(as: right), message, file: file, line: line)
    }

    @MainActor private final class MemoryDisk {
        var data: Data?
        var writes = 0
        var failWrites = false
        init(data: Data? = nil) { self.data = data }
        func store() -> NavigationRestorationStore {
            .init(read: { self.data }, write: { data in
                if self.failWrites { throw CocoaError(.fileWriteOutOfSpace) }
                self.data = data
                self.writes += 1
            })
        }
    }
}
