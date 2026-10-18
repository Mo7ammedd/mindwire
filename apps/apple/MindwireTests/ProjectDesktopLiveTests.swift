import XCTest
import UIKit
import SwiftUI
import Vision
@testable import Mindwire

/// Explicitly opted-in device test. Uses its own project, service, and virtual
/// desktop; the user's main console and installed workspace service are untouched.
@MainActor
final class ProjectDesktopLiveTests: XCTestCase {
    private struct NativeFixture: Decodable {
        let workspaceId: String
        let projectId: String
        let desktopId: String
        let port: Int
        let token: String
        let daemonToken: String
        let connection: DesktopSSHGrant
    }

    /// A simulator can exercise the real native SSH/RFB viewer with short-lived
    /// workspace credentials without copying a user's account login to it.
    func testNativeSavedDesktopWithScopedFixture() async throws {
        guard let file = ProcessInfo.processInfo.environment["MINDWIRE_PROJECT_NATIVE_FIXTURE"] else {
            throw XCTSkip("Requires a private fixture for a disposable virtual desktop.")
        }
        let fixture = try JSONDecoder().decode(NativeFixture.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        guard fixture.desktopId.hasPrefix("ds_") else { throw DesktopProblem(code: "fixture", message: "Use a disposable virtual desktop.") }
        try fixture.connection.validate(workspaceId: fixture.workspaceId, desktopId: fixture.desktopId)
        let port = fixture.port, token = fixture.token, daemonToken = fixture.daemonToken
        let channel = URLSessionDaemonChannel(label: "desktop-fixture") { method, path, body, _ in
            var request = URLRequest(url: URL(string: "https://workspace.oblien.com/proxy/\(port)\(path)")!)
            request.httpMethod = method; request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(daemonToken, forHTTPHeaderField: "X-Mindwire-Token")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        }
        let http = DaemonHTTP(channel: channel, agentType: "")
        let suite = "native-saved-desktop-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let workspace = Workspace(id: fixture.workspaceId, name: "Desktop verification", runtime: .cloud(workspaceId: fixture.workspaceId), createdAt: isoNow())
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in DesktopNativeFixtureRemote(api: http) }, resolveWorkspace: { $0 == workspace.id ? workspace : nil })
        let remote = CloudDesktopSessionsClient(workspace: workspace, projectId: fixture.projectId, stores: stores)
        let listed = try await remote.list()
        let desktop = try XCTUnwrap(listed.sessions.first { $0.id == fixture.desktopId && $0.name.hasPrefix("Mindwire native") })
        let selected = http.selectingDesktop(desktop.id)
        let provider = NativeSavedDesktopProvider(api: selected, grant: fixture.connection, desktopId: desktop.id)
        let model = DesktopModel(workspace: workspace, stores: stores, provider: provider, desktopId: desktop.id)
        defer { model.disconnect() }
        addTeardownBlock { @MainActor in
            if try await remote.list().sessions.contains(where: { $0.id == desktop.id }) { _ = try await remote.delete(desktop.id) }
        }
        await model.connect()
        try await waitForDesktop(model, width: 960)
        XCTAssertEqual(model.snapshot?.desktopId, desktop.id)
        model.send(.init(kind: "key", keys: ["Alt", "F2"]))
        XCTAssertTrue(model.inputBusy, "Accepted input is pending before its task starts.")
        try await drain(model)
        _ = try await waitForText("Run a Command", model: model)
        model.type("Mindwire desktop test")
        try await drain(model)
        let image = try await waitForText("Mindwire desktop test", model: model)
        let attachment = XCTAttachment(image: UIImage(cgImage: image)); attachment.name = "native-saved-desktop-input"; attachment.lifetime = .keepAlways
        add(attachment)
        try UIImage(cgImage: image).pngData()?.write(to: URL(fileURLWithPath: file + ".input.png"))
        model.send(.init(kind: "key", keys: ["Escape"]))
        try await drain(model)
        do {
            _ = try await remote.update(desktop.id, name: desktop.name, resolution: .init(width: 1024, height: 640))
            XCTFail("The runtime must require an explicit stop before resizing this desktop.")
        } catch let refusal as DaemonHTTPError {
            XCTAssertEqual(refusal.status, 409)
            XCTAssertEqual(refusal.message, "Stop this desktop before changing its resolution.")
        }
        _ = try await remote.update(desktop.id, name: "Mindwire native verified", resolution: nil)
        print("NATIVE_SAVED_DESKTOP selected SSH frames and visible keyboard text verified")
        model.suspend()
        XCTAssertNotNil(model.image)
        await model.resume()
        try await waitForDesktop(model, width: 960)
        XCTAssertEqual(model.snapshot?.desktopId, desktop.id)
        model.disconnect()
        let same = try await remote.ensureProject()
        XCTAssertEqual(same.id, desktop.id)
        _ = try await remote.stop(desktop.id)
        try await waitForStoppedDesktop(remote, id: desktop.id)
        _ = try await remote.update(desktop.id, name: "Mindwire native verified", resolution: .init(width: 1024, height: 640))
        _ = try await remote.start(desktop.id)
        await model.connect()
        try await waitForDesktop(model, width: 1024)
        model.disconnect()
        _ = try await remote.delete(desktop.id)
        print("NATIVE_SAVED_DESKTOP foreground resume, stable project association, stopped resize, restart and deletion passed")
    }

    func testSavedProjectDesktopOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MINDWIRE_PROJECT_DESKTOP_CHECK"] == "1" else {
            throw XCTSkip("Opt in with an isolated workspace service on the signed-in phone.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Use the signed-in phone for the SSH desktop check.")
        #else
        let workspaceId = try XCTUnwrap(env["MINDWIRE_DESKTOP_WORKSPACE"])
        let port = try XCTUnwrap(env["MINDWIRE_DESKTOP_DAEMON_PORT"].flatMap(Int.init))
        let token = try XCTUnwrap(env["MINDWIRE_DESKTOP_DAEMON_TOKEN"])
        let projectId = try XCTUnwrap(env["MINDWIRE_DESKTOP_PROJECT"])
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
        await MindwireAuth.shared.refresh()
        XCTAssertTrue(MindwireAuth.shared.authenticated)
        let live = try await MindwireCloud.client.workspaces.get(workspaceId)
        XCTAssertTrue(live.isRunning)
        let workspace = Workspace(id: workspaceId, name: live.name ?? "Desktop check", runtime: .cloud(workspaceId: workspaceId), createdAt: isoNow())
        let suite = "project-desktop-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let http = DaemonHTTP(channel: ProxyDaemonChannel(workspaceId: workspaceId, port: port, daemonToken: token), agentType: "")
        let coordinator = DaemonWorkCoordinator(defaults: defaults)
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: {
            WorkspaceRegistryClient(workspace: $0, stores: stores, http: http, coordinator: coordinator)
        }, resolveWorkspace: { $0 == workspaceId ? workspace : nil })
        let repository = WorkspaceRepository(stores: stores, adapters: [DesktopCheckAdapter(workspace)])
        let remote = CloudDesktopSessionsClient(workspace: workspace, projectId: projectId, stores: stores)
        let initial = try await remote.list()
        XCTAssertEqual(initial.capabilities.mode, "virtual")
        XCTAssertTrue(initial.sessions.isEmpty, "Use a fresh disposable project.")
        let draft = DesktopCreationDraft(name: "Mindwire iPhone desktop check", resolution: .init(width: 960, height: 640))
        let desktop = try await remote.create(draft)
        XCTAssertNotEqual(desktop.id, "console")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let receipt = directory.appendingPathComponent("MindwireProjectDesktopReceipt.json")
        try JSONSerialization.data(withJSONObject: ["workspaceId": workspaceId, "desktopId": desktop.id])
            .write(to: receipt, options: [.atomic, .completeFileProtection])
        addTeardownBlock { @MainActor in
            let remaining = try await remote.list()
            if remaining.sessions.contains(where: { $0.id == desktop.id }) { _ = try await remote.delete(desktop.id) }
            try? FileManager.default.removeItem(at: receipt)
        }
        let replay = try await remote.create(draft)
        XCTAssertEqual(replay.id, desktop.id)
        let linked = try await remote.list()
        XCTAssertEqual(linked.sessions.map(\.id), [desktop.id])
        let catalog = try await MindwireCloud.client.workspace(workspaceId).desktop.sessions.list()
        XCTAssertTrue(catalog.sessions.contains { $0.id == desktop.id })
        print("PROJECT_DESKTOP_PHONE created one saved desktop through the project catalog")

        let model = try XCTUnwrap(repository.desktopModel(for: workspaceId, desktopId: desktop.id))
        defer { model.disconnect() }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow))
        var presenting = try XCTUnwrap(window.rootViewController)
        while let top = presenting.presentedViewController { presenting = top }
        let screen = UIHostingController(rootView: DesktopScreen(workspaceId: workspaceId, desktopId: desktop.id,
            desktopName: desktop.name, repository: repository))
        screen.modalPresentationStyle = .fullScreen
        presenting.present(screen, animated: false)
        defer { screen.dismiss(animated: false) }
        await model.connect()
        try await waitForDesktop(model, width: 960)
        XCTAssertEqual(model.snapshot?.desktopId, desktop.id)
        XCTAssertTrue(model.controlsDesktop, model.error ?? "The phone did not acquire the available controller.")
        let selected = http.selectingDesktop(desktop.id)
        let control = try XCTUnwrap(model.snapshot?.controller)
        model.send(.init(kind: "key", keys: ["Alt", "F2"]))
        try await drain(model)
        _ = try await waitForText("Run a Command", model: model)
        model.type("Mindwire desktop test")
        try await drain(model)
        _ = try await waitForText("Mindwire desktop test", model: model)
        let capture: DesktopCapture = try await selected.decode("POST", "/surfaces/desktop/sessions/\(control.sessionId)/captures", quiet: true)
        XCTAssertEqual(capture.surfaceId, desktop.id)
        let artifact: DesktopArtifact = try await selected.decode("GET", "/artifacts/\(capture.artifactId)", quiet: true)
        let captured = try XCTUnwrap(UIImage(data: artifact.data))
        let attachment = XCTAttachment(image: captured); attachment.name = "project-desktop-phone-input"; attachment.lifetime = .keepAlways
        add(attachment)
        model.send(.init(kind: "key", keys: ["Escape"]))
        try await drain(model)
        print("PROJECT_DESKTOP_PHONE selected SSH stream, default control, and keyboard input passed")

        let renamed = try await remote.update(desktop.id, name: "Mindwire iPhone verified", resolution: nil)
        XCTAssertEqual(renamed.id, desktop.id)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let screenAttachment = XCTAttachment(image: image); screenAttachment.name = "project-desktop-phone-viewer"; screenAttachment.lifetime = .keepAlways
        add(screenAttachment)
        model.suspend()
        XCTAssertFalse(model.connected)
        XCTAssertNotNil(model.image)
        await model.resume()
        try await waitForDesktop(model, width: 960)
        XCTAssertEqual(model.snapshot?.desktopId, desktop.id)
        print("PROJECT_DESKTOP_PHONE rename and foreground reconnect kept the same desktop")

        model.disconnect()
        let ensured = try await remote.ensureProject()
        XCTAssertEqual(ensured.id, desktop.id)
        _ = try await remote.stop(desktop.id)
        try await waitForStoppedDesktop(remote, id: desktop.id)
        let resized = try await remote.update(desktop.id, name: "Mindwire iPhone verified", resolution: .init(width: 1024, height: 640))
        XCTAssertEqual(resized.id, desktop.id)
        await model.connect()
        try await waitForDesktop(model, width: 1024)
        XCTAssertEqual(model.snapshot?.desktopId, desktop.id)
        model.disconnect()
        _ = try await remote.delete(desktop.id)
        let deleted = try await remote.list()
        XCTAssertFalse(deleted.sessions.contains { $0.id == desktop.id && $0.state != "deleting" })
        print("PROJECT_DESKTOP_PHONE close/reopen, stopped resize, start stopped desktop, and stop-before-delete passed")
        #endif
    }

    private func waitForStoppedDesktop(_ remote: CloudDesktopSessionsClient, id: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let list = try await remote.list()
            if list.sessions.first(where: { $0.id == id })?.state == "stopped" { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw DesktopProblem(code: "test_connection", message: "The disposable desktop did not stop.")
    }

    private func waitForDesktop(_ model: DesktopModel, width: Int) async throws {
        let deadline = Date().addingTimeInterval(50)
        while Date() < deadline {
            if model.acceptsInput, let image = model.image, image.width == width { return }
            if model.error != nil, !model.recovery.active, !model.busy { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DesktopProblem(code: "test_connection", message: model.error ?? "The selected desktop did not deliver \(width)-pixel frames and control.")
    }

    private func drain(_ model: DesktopModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while (model.inputBusy || model.inputSynchronizing || !model.acceptsInput), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(model.inputBusy)
        XCTAssertFalse(model.inputSynchronizing)
        XCTAssertTrue(model.acceptsInput, "Wait for fresh display acknowledgement before the next gesture.")
        XCTAssertNil(model.error)
    }

    /// Verify the actual native pixels after one input dispatch, rather than
    /// treating an accepted action receipt as proof that text reached the UI.
    private func waitForText(_ text: String, model: DesktopModel) async throws -> CGImage {
        print("NATIVE_DESKTOP waiting for visible text: \(text)")
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var lastVisible = ""
        while ProcessInfo.processInfo.systemUptime < deadline, model.error == nil {
            if let image = model.image {
                // Vision's initial model load can take seconds on the simulator.
                // Keep the app's UI, input watchdog and frame callbacks running.
                let visible = try await Task.detached(priority: .userInitiated) {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
                }.value
                lastVisible = visible
                if visible.localizedCaseInsensitiveContains(text) {
                    print("NATIVE_DESKTOP visible text verified: \(text)")
                    return image
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        print("NATIVE_DESKTOP expected: \(text); observed: \(lastVisible); state: \(model.error ?? "no connection error")")
        if let image = model.image {
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "native-desktop-unexpected-input"; attachment.lifetime = .keepAlways; add(attachment)
        }
        throw DesktopProblem(code: "test_input", message: model.error ?? "The desktop did not display the expected text: \(text)")
    }
}

/// Only grant acquisition is supplied by the fixture. The production model,
/// API channel, pinned SSH connection, decoder, input queue and leases are used.
@MainActor
private final class NativeSavedDesktopProvider: WorkspaceDesktopProvider {
    let api: DaemonHTTP
    let grant: DesktopSSHGrant
    let desktopId: String
    init(api: DaemonHTTP, grant: DesktopSSHGrant, desktopId: String) { self.api = api; self.grant = grant; self.desktopId = desktopId }
    func status() async throws -> DesktopProviderStatus {
        let value: DesktopSnapshot = try await api.decode("GET", "/surfaces/desktop?refresh=true", quiet: true)
        return .init(supported: value.supported, enabled: value.enabled, available: value.available, credentials: false)
    }
    func authorize(api: DaemonHTTP, status: DesktopProviderStatus, resuming: Bool) async throws -> DesktopSnapshot {
        let value: DesktopSnapshot = try await api.decode("GET", "/surfaces/desktop?refresh=true", quiet: true)
        guard value.desktopId == desktopId else { throw DesktopProblem(code: "fixture", message: "Wrong saved desktop.") }
        return value
    }
    func openDisplay(api: DaemonHTTP, session: DesktopSession) async throws -> DesktopDisplayConnection {
        guard session.desktopId == desktopId else { throw DesktopProblem(code: "fixture", message: "Wrong control session.") }
        let ssh = SSHConnection(host: grant.ssh.host, port: grant.ssh.port, username: grant.ssh.username,
            auth: .password(grant.ssh.password), expectedHostKey: grant.ssh.host_key_fingerprint)
        do {
            let forward = try await ssh.forwardLocal(host: grant.vnc.host, port: grant.vnc.port)
            return DesktopDisplayConnection(port: forward.port) { forward.close(); ssh.close() }
        } catch { ssh.close(); throw error }
    }
}
