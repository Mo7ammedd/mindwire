import XCTest
import SwiftUI
import UIKit
import OblienKit
@testable import Mindwire

@MainActor
final class DesktopSessionsTests: XCTestCase {
    private func model(_ remote: SessionRemote, defaults: UserDefaults? = nil) -> DesktopSessionsModel {
        let suite = "desktop-sessions-tests-\(UUID().uuidString)"
        let storage = defaults ?? UserDefaults(suiteName: suite)!
        if defaults == nil { addTeardownBlock { storage.removePersistentDomain(forName: suite) } }
        return DesktopSessionsModel(remote: remote, recoveryKey: "pending", defaults: storage)
    }

    func testConcurrentLoadsShareRequestAndCacheSurvivesNavigation() async throws {
        let remote = try SessionRemote()
        remote.delay = .milliseconds(40)
        let model = model(remote)
        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        _ = await (first, second)
        await model.refresh()
        XCTAssertEqual(remote.loads, 1)
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertTrue(model.loaded)
        remote.failList = true
        await model.refresh(force: true)
        XCTAssertEqual(model.sessions.count, 2, "A failed refresh must keep the existing list")
        XCTAssertNotNil(model.loadError)
    }

    func testUncertainCreationSurvivesModelReopenWithIdenticalRequest() async throws {
        let suite = "desktop-create-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let remote = try SessionRemote()
        remote.failCreateOnce = true
        let first = model(remote, defaults: defaults)
        await first.refresh()
        let draft = first.draft(name: "My app")
        let lost = await first.create(draft)
        XCTAssertNil(lost)
        let reopened = model(remote, defaults: defaults)
        XCTAssertEqual(reopened.pendingCreation, draft)
        let restored = await reopened.create(reopened.draft(name: "Other name"))
        XCTAssertNotNil(restored)
        XCTAssertNil(reopened.pendingCreation)
        XCTAssertNil(defaults.data(forKey: "pending"))
        XCTAssertEqual(remote.creates, [draft, draft])
    }

    func testRepeatedCreateAndStopCannotDispatchTwice() async throws {
        let remote = try SessionRemote(); remote.delay = .milliseconds(40)
        let model = model(remote)
        await model.refresh()
        let draft = model.draft(name: "App")
        async let a = model.create(draft)
        async let b = model.create(draft)
        _ = await (a,b)
        XCTAssertEqual(remote.creates.count, 1)
        let desktop = try XCTUnwrap(model.sessions.first)
        async let stop1: Void = model.stop(desktop)
        async let stop2: Void = model.stop(desktop)
        _ = await (stop1,stop2)
        XCTAssertEqual(remote.stops, 1)
        XCTAssertEqual(model.sessions.first?.state, "stopped")
    }

    func testRejectedCreationCanBeEditedAndRetriedWithNewKey() async throws {
        let remote = try SessionRemote()
        let model = model(remote)
        await model.refresh()
        let draft = model.draft(name: "My app")
        remote.createError = DaemonHTTPError(status: 400, message: "Use a supported resolution", code: "invalid_request")
        let rejected = await model.create(draft)
        XCTAssertNil(rejected)
        XCTAssertNil(model.pendingCreation)
        XCTAssertNotNil(model.operationError)
        let corrected = model.draft(name: "My app corrected")
        XCTAssertNotEqual(corrected.requestId, draft.requestId)
        remote.createError = nil
        let saved = await model.create(corrected)
        XCTAssertNotNil(saved)
        XCTAssertEqual(remote.creates, [draft, corrected])
    }

    func testConsoleCapabilitiesAndDeletingSessionPreventInvalidControls() throws {
        let console = try SessionRemote.desktop(id: "console", state: "running", extra: #", "can_resize": false, "can_delete": false"#)
        XCTAssertFalse(console.supportsResize)
        XCTAssertFalse(console.supportsDelete)
        let deleting = try SessionRemote.desktop(state: "deleting", extra: #", "deletion_pending": true"#)
        XCTAssertFalse(deleting.canConnect)
        XCTAssertTrue(deleting.isTransitioning)
    }

    func testRenameDoesNotSendResolutionOrStopRunningDesktop() async throws {
        let remote = try SessionRemote()
        let model = model(remote)
        await model.refresh()
        let running = try XCTUnwrap(model.sessions.first)
        let renamed = await model.save(running, name: "Renamed", resolution: running.resolution)
        XCTAssertNotNil(renamed)
        XCTAssertEqual(remote.updates.count, 1)
        XCTAssertEqual(remote.updates.first?.name, "Renamed")
        XCTAssertNil(remote.updates.first?.resolution)
        XCTAssertEqual(remote.stops, 0)
    }

    func testResolutionChangesRequireStoppedDesktopAndNeverImplicitlyStopApps() async throws {
        let remote = try SessionRemote()
        let model = model(remote)
        await model.refresh()
        let running = try XCTUnwrap(model.sessions.first)
        let stopped = try XCTUnwrap(model.sessions.last)
        let size = DesktopResolution(width: 1440, height: 900)
        let rejected = await model.save(running, name: running.name, resolution: size)
        XCTAssertNil(rejected)
        XCTAssertTrue(remote.updates.isEmpty)
        XCTAssertEqual(remote.stops, 0)
        XCTAssertEqual(model.operationError, "Stop this desktop before changing its resolution.")
        let saved = await model.save(stopped, name: stopped.name, resolution: size)
        XCTAssertNotNil(saved)
        XCTAssertEqual(remote.updates.first?.resolution, size)
    }

    func testDesktopSelectorPreservesAgentAndDoesNotChangeOtherWorkspaceRequests() {
        let http = DaemonHTTP(channel: DesktopNoNetworkChannel(), agentType: "claude-code").selectingDesktop("ds_0123456789abcdef")
        XCTAssertEqual(http.scoped("/surfaces/desktop/events"), "/surfaces/desktop/events?agent=claude-code&desktopId=ds_0123456789abcdef")
        XCTAssertEqual(http.scoped("/surfaces/desktop?refresh=true"), "/surfaces/desktop?refresh=true&agent=claude-code&desktopId=ds_0123456789abcdef")
        XCTAssertEqual(http.scoped("/workspace"), "/workspace?agent=claude-code")
    }

    func testDesktopPickerAndSettingsNativeLayout() async throws {
        let model = model(try SessionRemote())
        await model.refresh()
        try await screenshot(DesktopSessionsScreen(workspaceId: "test", model: model), name: "mindwire-desktop-sessions")
        try await screenshot(DesktopSessionEditor(model: model, desktop: nil, defaultName: "My project", completion: { _ in }), name: "mindwire-desktop-create")
    }

    private func screenshot<V: View>(_ view: V, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: view.preferredColorScheme(.dark).labelIconToTitleSpacing(Spacing.md))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        XCTAssertGreaterThan(controller.view.bounds.width, 300)
    }
}

@MainActor
private final class SessionRemote: DesktopSessionsRemote {
    var loads = 0
    var creates: [DesktopCreationDraft] = []
    var stops = 0
    var updates: [(name: String, resolution: DesktopResolution?)] = []
    var failList = false
    var failCreateOnce = false
    var createError: Error?
    var delay: Duration = .zero
    let listValue: DesktopSessionList
    init() throws {
        let data = Data(#"{"success":true,"sessions":[{"id":"ds_0123456789abcdef","name":"My project","state":"running","available":true,"managed":true,"resolution":{"width":1280,"height":800}},{"id":"ds_1123456789abcdef","name":"Browser testing","state":"stopped","available":false,"managed":true,"resolution":{"width":1920,"height":1080}}],"capabilities":{"mode":"virtual","max_sessions":10,"can_create":true,"resolution":{"min":{"width":640,"height":480},"max":{"width":3840,"height":2160},"default":{"width":1280,"height":800}}}}"#.utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        listValue = try decoder.decode(DesktopSessionList.self, from: data)
    }
    func list() async throws -> DesktopSessionList {
        loads += 1; try await Task.sleep(for: delay)
        if failList { throw URLError(.networkConnectionLost) }
        return listValue
    }
    func create(_ draft: DesktopCreationDraft) async throws -> SavedWorkspaceDesktop {
        creates.append(draft); try await Task.sleep(for: delay)
        if let createError { throw createError }
        if failCreateOnce { failCreateOnce = false; throw URLError(.networkConnectionLost) }
        return try Self.desktop()
    }
    func ensureProject() async throws -> SavedWorkspaceDesktop { try Self.desktop() }
    func update(_ id: String, name: String, resolution: DesktopResolution?) async throws -> SavedWorkspaceDesktop {
        updates.append((name, resolution))
        return try Self.desktop(id: id)
    }
    func start(_ id: String) async throws -> SavedWorkspaceDesktop { try Self.desktop(id: id) }
    func stop(_ id: String) async throws -> SavedWorkspaceDesktop { stops += 1; try await Task.sleep(for: delay); return try Self.desktop(id: id, state: "stopped") }
    func delete(_ id: String) async throws -> SavedWorkspaceDesktop? { nil }
    static func desktop(id: String = "ds_0123456789abcdef", state: String = "running", extra: String = "") throws -> SavedWorkspaceDesktop {
        let data = Data("{\"id\":\"\(id)\",\"name\":\"My project\",\"state\":\"\(state)\",\"managed\":true,\"available\":true\(extra)}".utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SavedWorkspaceDesktop.self, from: data)
    }
}

@MainActor private final class DesktopNoNetworkChannel: DaemonChannel {
    var label: String { "test" }
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) { throw URLError(.unsupportedURL) }
}
