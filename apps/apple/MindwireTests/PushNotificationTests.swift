import XCTest
import SwiftUI
import UserNotifications
@testable import Mindwire

@MainActor
final class PushNotificationTests: XCTestCase {
    func testSignedOutPhoneShowsTheMissingLoginInsteadOfReportingNotificationsReady() async {
        let registry = PushRegistryFixture(), permission = PushPermissionFixture()
        let service = LivePushService(api: registry, tokens: PushTokenFixture("token"),
            authorization: permission, accountID: { nil }, deviceID: { "device" })
        await service.start()
        XCTAssertEqual(service.authorizationStatus, .authorized)
        XCTAssertEqual(service.state, .signInRequired,
                       "iOS allowing alerts does not mean the phone has a working delivery registration")
        XCTAssertTrue(registry.tokens.isEmpty)
    }

    func testConcurrentStartupCallsSharePermissionAndDeviceRegistration() async {
        let registry = PushRegistryFixture(), permission = PushPermissionFixture()
        permission.current = .notDetermined
        registry.delay = true
        let service = makeService(registry, PushTokenFixture("current"), permission)
        async let first: Void = service.start()
        async let second: Void = service.start()
        async let third: Void = service.start()
        _ = await (first, second, third)
        XCTAssertEqual(permission.requests, 1)
        XCTAssertEqual(permission.remoteRegistrations, 1)
        XCTAssertEqual(registry.tokens, ["current"])
        XCTAssertEqual(service.state, .ready)
    }

    func testFailedRegistrationRetriesInForegroundAndStopsAfterRecovery() async throws {
        let registry = PushRegistryFixture()
        registry.failure = APIError.transport("offline")
        registry.failOnce = true
        var provisioned = 0
        let service = LivePushService(api: registry, tokens: PushTokenFixture("current"),
            authorization: PushPermissionFixture(), accountID: { 1 }, deviceID: { "device" },
            didRegister: { provisioned += 1 }, retryDelay: { _ in .milliseconds(40) })
        service.setActive(true)
        defer { service.setActive(false) }
        await service.start()
        XCTAssertTrue(service.state.needsRetry)
        for _ in 0..<100 where service.state != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.state, .ready)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(registry.tokens, ["current", "current"])
        XCTAssertEqual(provisioned, 1, "Successful registration reconfigures connected workspace delivery once")
        let reads = registry.statusReads
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(registry.statusReads, reads, "A healthy registration has no polling timer")
    }

    func testBackgroundingStopsFailedRegistrationRetries() async throws {
        let registry = PushRegistryFixture()
        registry.failure = APIError.transport("offline")
        let service = LivePushService(api: registry, tokens: PushTokenFixture("current"),
            authorization: PushPermissionFixture(), accountID: { 1 }, deviceID: { "device" },
            retryDelay: { _ in .milliseconds(70) })
        service.setActive(true)
        await service.start()
        service.setActive(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(registry.tokens, ["current"])
    }

    func testNetworkRecoveryRetriesWithoutWaitingForAnotherAppLaunch() async throws {
        let registry = PushRegistryFixture(), network = ComputerNetworkMonitor(observeSystem: false)
        network.update(.init(reachable: false))
        registry.failure = APIError.transport("offline")
        let service = LivePushService(api: registry, tokens: PushTokenFixture("current"),
            authorization: PushPermissionFixture(), accountID: { 1 }, deviceID: { "device" }, network: network,
            retryDelay: { _ in .seconds(300) })
        service.setActive(true)
        defer { service.setActive(false) }
        await service.start()
        registry.failure = nil
        network.update(.init(reachable: true, interfaces: ["en0"]))
        for _ in 0..<100 where service.state != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(registry.tokens, ["current", "current"])
    }

    func testAccountChangeDuringRegistrationDoesNotLoseTheNewAccount() async throws {
        let registry = PushRegistryFixture()
        registry.delay = true
        var account: Int? = 1
        let service = LivePushService(api: registry, tokens: PushTokenFixture("current"),
            authorization: PushPermissionFixture(), accountID: { account }, deviceID: { "device" })
        let first = Task { await service.start() }
        while registry.tokens.isEmpty { await Task.yield() }
        account = 2
        await service.start()
        await first.value
        XCTAssertEqual(service.state, .ready)
        XCTAssertEqual(registry.tokens, ["current", "current"])
    }

    func testReturningInstallRegistersWithoutTokenRefreshCallback() async {
        let registry = PushRegistryFixture(), permission = PushPermissionFixture()
        let service = makeService(registry, PushTokenFixture("existing"), permission)
        await service.start()
        XCTAssertEqual(permission.remoteRegistrations, 1)
        XCTAssertEqual(registry.tokens, ["existing"])
        XCTAssertEqual(registry.deviceInfo?["bundle_id"], "com.oblien.mindwire")
        let ready = await service.isRegistered()
        XCTAssertTrue(ready)
    }

    func testAPNsArrivalRetriesRegistrationAfterInitialMissingToken() async {
        let registry = PushRegistryFixture(), tokens = PushTokenFixture(nil)
        let service = makeService(registry, tokens)
        await service.start()
        XCTAssertTrue(registry.tokens.isEmpty)
        await tokens.set("after-apns")
        let registered = await service.registerIfPossible()
        XCTAssertTrue(registered)
        XCTAssertEqual(registry.tokens, ["after-apns"])
    }

    func testForegroundChecksActiveDeviceWithoutRepeatedUpserts() async {
        let registry = PushRegistryFixture()
        let service = makeService(registry, PushTokenFixture("stable"))
        await service.start()
        await service.start()
        await service.start()
        XCTAssertEqual(registry.tokens, ["stable"])
    }

    func testForegroundRetriesFailedAndRevokedRegistrations() async {
        let registry = PushRegistryFixture()
        registry.failure = APIError.transport("offline")
        let service = makeService(registry, PushTokenFixture("current"))
        await service.start()
        registry.failure = nil
        await service.start()
        registry.active = false
        await service.start()
        XCTAssertEqual(registry.tokens, ["current", "current", "current"])
        let ready = await service.isRegistered()
        XCTAssertTrue(ready)
    }

    func testDeniedPermissionAndAnonymousAccountNeverRegister() async {
        let registry = PushRegistryFixture(), permission = PushPermissionFixture()
        permission.current = .denied
        let service = makeService(registry, PushTokenFixture("token"), permission)
        await service.start()
        let denied = await service.registerIfPossible()
        XCTAssertFalse(denied)
        XCTAssertEqual(permission.remoteRegistrations, 0)
        permission.current = .authorized
        let anonymous = LivePushService(api: registry, tokens: PushTokenFixture("token"),
                                        authorization: permission, accountID: { nil }, deviceID: { "device" })
        await anonymous.start()
        let registered = await anonymous.registerIfPossible()
        XCTAssertFalse(registered)
        XCTAssertTrue(registry.tokens.isEmpty)
    }

    func testOverlappingCallbacksShareRegistrationButKeepNewToken() async {
        let registry = PushRegistryFixture()
        registry.delay = true
        let tokens = PushTokenFixture("old")
        let live = makeService(registry, tokens)
        let first = Task { await live.registerIfPossible() }
        while registry.tokens.isEmpty { await Task.yield() }
        let duplicate = Task { await live.registerIfPossible() }
        try? await Task.sleep(for: .milliseconds(10))
        await tokens.set("rotated")
        let rotation = Task { await live.registerIfPossible() }
        _ = await (first.value, duplicate.value, rotation.value)
        XCTAssertEqual(registry.tokens, ["old", "rotated"])
    }

    func testInvalidFCMTokenIsReplacedAndRetriedOnce() async {
        let registry = PushRegistryFixture()
        registry.failure = APIError.http(status: 400, detail: "{\"error\":\"invalid_device_token\"}")
        registry.failOnce = true
        let tokens = PushTokenFixture("invalid", replacement: "fresh")
        let registered = await makeService(registry, tokens).registerIfPossible()
        XCTAssertTrue(registered)
        XCTAssertEqual(registry.tokens, ["invalid", "fresh"])
        let deletes = await tokens.deletes
        XCTAssertEqual(deletes, 1)
    }

    func testLogoutWaitsForRegistrationThenRemovesAndInvalidatesToken() async {
        let registry = PushRegistryFixture()
        registry.delay = true
        let tokens = PushTokenFixture("old")
        let live = makeService(registry, tokens)
        let pending = Task { await live.registerIfPossible() }
        while registry.tokens.isEmpty { await Task.yield() }
        await live.unregister()
        _ = await pending.value
        XCTAssertEqual(registry.operations, ["register", "remove"])
        let callbackAfterLogout = await live.registerIfPossible()
        XCTAssertFalse(callbackAfterLogout)
        let deletes = await tokens.deletes
        XCTAssertEqual(deletes, 1)
    }

    func testPushRoutingAcceptsFlattenedNestedAndUnifiedDaemonPayloads() {
        XCTAssertEqual(PushTarget(payload: ["target_type": "chat", "target_id": "c1"]), .chat("c1"))
        XCTAssertEqual(PushTarget(payload: ["data": ["chatId": "c2", "agent": "codex"]]), .chat("c2"))
        XCTAssertEqual(PushTarget(payload: ["data": "{\"chatId\":\"c3\"}"]), .chat("c3"))
        XCTAssertEqual(PushTarget(payload: ["workspace_id": "w1", "data": ["condition": "error"]]), .workspace("w1"))
        XCTAssertNil(PushTarget(payload: ["agent": "codex"]))
        XCTAssertNil(PushTarget(payload: ["chatId": "  "]))
    }

    func testColdLaunchTapWaitsUntilAppIsAttached() {
        let router = PushRouter()
        router.route(.chat("c1"))
        let defaults = UserDefaults(suiteName: "PushNotificationTests.\(UUID())")!
        let app = AppModel(stores: Stores(defaults: defaults))
        router.attach(app)
        XCTAssertEqual(app.selectedTab, .agents)
        XCTAssertEqual(app.agentsPath.count, 1)
        router.attach(app)
        XCTAssertEqual(app.agentsPath.count, 1)
    }

    func testRepeatedNotificationOpensReuseTheCachedChatAndOneDestination() throws {
        let suite = "push-navigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults), app = AppModel(stores: stores)
        let model = stores.chatSessions.model(for: "chat")
        let presentation = model.presentationID
        model.messages = [.init(id: "saved", chatId: "chat", role: .assistant, text: "Cached answer", createdAt: "")]
        let router = PushRouter()
        router.route(.chat("chat"), notificationID: "notification")
        router.attach(app)
        router.route(.chat("chat"), notificationID: "notification")
        XCTAssertEqual(app.agentsPath.count, 1, "Repeated taps before onAppear must not stack the same chat")
        XCTAssertTrue(stores.chatSessions.model(for: "chat") === model)
        XCTAssertEqual(model.presentationID, presentation, "The transcript/disclosures must not be recreated to scroll")
        XCTAssertEqual(model.messages.map(\.text), ["Cached answer"])
        XCTAssertEqual(model.latestRequestRevision, 2, "Every tap can reveal the tail even without fetching history")
    }

    func testNotificationReusesAChatInItsExistingTabButNotAPoppedLocation() throws {
        let suite = "push-tabs-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(stores: Stores(defaults: defaults))
        app.projectsPath.append(AppRoute.projectDetail(id: "project"))
        app.projectsPath.append(AppRoute.chat(chatId: "chat"))
        app.rememberChatLocation("chat")
        app.selectedTab = .workspaces
        app.open(.chat("chat"), notificationID: "first")
        XCTAssertEqual(app.selectedTab, .projects)
        XCTAssertEqual(app.projectsPath.count, 2)
        XCTAssertTrue(app.agentsPath.isEmpty)
        app.open(.chat("chat"), notificationID: "second")
        XCTAssertEqual(app.projectsPath.count, 2)

        app.projectsPath.removeLast()
        app.open(.chat("chat"), notificationID: "third")
        XCTAssertEqual(app.selectedTab, .agents)
        XCTAssertEqual(app.agentsPath.count, 1, "The old path snapshot must not mistake a project page for the chat")
    }

    func testChatInALocalToolStackCannotReplaceTheMainTabLocation() async throws {
        let suite = "push-local-stack-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults), app = AppModel(stores: stores)
        app.projectsPath.append(AppRoute.projectDetail(id: "project"))
        let chat = stores.createChat(agentId: "agent", projectId: "project", title: "Tool chat")
        let model = stores.chatSessions.model(for: chat.id)
        model.messages = [.init(id: "saved", chatId: chat.id, role: .assistant, text: "Saved answer", createdAt: "")]
        let host = UIHostingController(rootView: NavigationStack {
            ChatScreen(chatId: chat.id)
        }.environment(app).environment(\.stores, stores).environment(\.scenePhase, .inactive))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; model.dispose() }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        window.isHidden = true // Files/Source Control's local navigation has been dismissed.
        app.open(.chat(chat.id), notificationID: "after-tool-closed")
        XCTAssertEqual(app.selectedTab, .agents)
        XCTAssertEqual(app.agentsPath.count, 1, "The tool chat never occupied the project's tab path")
    }

    private func makeService(_ registry: PushRegistryFixture, _ tokens: PushTokenFixture,
                             _ permission: PushPermissionFixture? = nil) -> LivePushService {
        LivePushService(api: registry, tokens: tokens, authorization: permission ?? PushPermissionFixture(),
                        accountID: { 1 }, deviceID: { "device" })
    }
}

@MainActor
private final class PushPermissionFixture: PushAuthorization {
    var current: UNAuthorizationStatus = .authorized
    var remoteRegistrations = 0
    var requests = 0
    func status() async -> UNAuthorizationStatus { current }
    func request() async throws -> Bool { requests += 1; current = .authorized; return true }
    func registerForRemoteNotifications() { remoteRegistrations += 1 }
}

private actor PushTokenFixture: FCMTokenProvider {
    var token: String?, replacement: String?
    var deletes = 0
    init(_ token: String?, replacement: String? = nil) { self.token = token; self.replacement = replacement }
    func set(_ token: String?) { self.token = token }
    func currentToken() async -> String? { token }
    func deleteToken() async throws { deletes += 1; token = replacement }
}

@MainActor
private final class PushRegistryFixture: PushDeviceRegistry {
    var tokens: [String] = [], operations: [String] = []
    var deviceInfo: [String: String]?
    var failure: Error?
    var failOnce = false, delay = false, active = false
    var statusReads = 0
    func registerDevice(deviceId: String, fcmToken: String, platform: String,
                        deviceInfo: [String: String]?) async throws -> PushDevice {
        tokens.append(fcmToken); operations.append("register"); self.deviceInfo = deviceInfo
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        if let failure {
            if failOnce { self.failure = nil }
            throw failure
        }
        active = true
        return PushDevice(id: 7, deviceId: deviceId, platform: platform, status: "active")
    }
    func status(deviceId: String) async throws -> DeviceStatus {
        statusReads += 1
        return DeviceStatus(registered: !tokens.isEmpty, status: active ? "active" : "revoked", id: tokens.isEmpty ? nil : 7)
    }
    func removeDevice(id: Int) async throws { operations.append("remove"); active = false }
}
