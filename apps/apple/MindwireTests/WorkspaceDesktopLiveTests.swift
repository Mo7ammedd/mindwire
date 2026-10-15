import XCTest
import UIKit
import SwiftUI
@testable import Mindwire

/// Device checks require explicit opt-in. Scoped credentials never enter test output.
@MainActor
final class WorkspaceDesktopLiveTests: XCTestCase {
    /// Uses the installed release and normal app connection path; never installs
    /// a development service or replaces a workspace binary.
    func testSignedInForegroundResume() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MINDWIRE_DESKTOP_UX_CHECK"] == "1", let workspaceId = env["MINDWIRE_DESKTOP_WORKSPACE"] else {
            throw XCTSkip("Opt in on the signed-in phone for a desktop UX check.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Use the signed-in phone.")
        #else
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
        await OblienAuth.shared.refresh()
        let live = try await OblienCloud.client.workspaces.get(workspaceId)
        XCTAssertTrue(live.isRunning)
        let workspace = Workspace(id: workspaceId, name: live.name ?? "Desktop",
            runtime: .cloud(workspaceId: workspaceId), createdAt: isoNow())
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let diagnosticFixture = directory.appendingPathComponent("MindwireInstallFixture.json")
        if env["MINDWIRE_DESKTOP_DIAGNOSTICS"] == "1" {
            let token = try await CloudDesktopProvider(workspaceId: workspaceId).gatewayToken()
            try JSONSerialization.data(withJSONObject: ["workspaceId": workspaceId, "token": token,
                "baseURL": OblienCloud.client.config.runtimeURL.absoluteString])
                .write(to: diagnosticFixture, options: [.atomic, .completeFileProtection])
            let boot = try await CloudWorkspaceService(workspaceId: workspaceId).exec(["/bin/sh", "-c",
                "uname -s; uptime; sysctl -n kern.boottime 2>/dev/null || true; pgrep -x mindwired || true"])
            print("DESKTOP_UX_CHECK workspace startup: \(boot.stdout.oneLine())")
        }
        let suite = "desktop-resume-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let repository = WorkspaceRepository(stores: stores, adapters: [DesktopCheckAdapter(workspace)])
        let model = try XCTUnwrap(repository.desktopModel(for: workspaceId))
        defer { model.disconnect() }
        // This explicitly opted-in device check may follow a VM reboot. Exercise
        // the app's Start service action without downloading or replacing it.
        try await WorkspaceRegistryClient(workspace: workspace, stores: stores).startDaemon()
        let api = try await stores.workspaceData.desktopHTTP(workspace)
        let before: DesktopSnapshot = try await api.decode("GET", "/surfaces/desktop", quiet: true)
        guard before.controller == nil else { throw XCTSkip("An existing controller is using the desktop.") }

        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow))
        var presenting = try XCTUnwrap(window.rootViewController)
        while let top = presenting.presentedViewController { presenting = top }
        let screen = UIHostingController(rootView: DesktopScreen(workspaceId: workspaceId, repository: repository))
        screen.modalPresentationStyle = .fullScreen
        presenting.present(screen, animated: false)
        defer { screen.dismiss(animated: false) }
        await model.connect()
        try await waitForDesktop(model)
        XCTAssertNil(model.signInNotice, "The provider's existing-session preparation should succeed.")
        XCTAssertTrue(DesktopOrientations.supported(for: window).contains(.landscapeLeft))
        XCTAssertFalse(model.controlsDesktop)
        await model.takeControl()
        XCTAssertTrue(model.controlsDesktop, model.error ?? "Control was not acquired.")
        model.send(.init(kind: "key", keys: ["Shift"]))
        await Task.yield()
        let inputDeadline = Date().addingTimeInterval(15)
        while model.inputBusy, Date() < inputDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(model.error)
        // Check that an idle viewer keeps its controller before suspending it.
        let controller = model.snapshot?.controller?.sessionId
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(model.snapshot?.controller?.sessionId, controller)
        XCTAssertTrue(model.connected)
        model.suspend()
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.controlsDesktop)
        XCTAssertNotNil(model.image, "Keep the last frame while the foreground connection resumes.")
        try await Task.sleep(for: .seconds(1))
        let released: DesktopSnapshot = try await api.decode("GET", "/surfaces/desktop", quiet: true)
        XCTAssertNil(released.controller)

        let other: DesktopSession = try await api.decode("POST", "/surfaces/desktop/sessions",
            json: ["requestId": UUID().uuidString, "mode": "view", "name": "Foreground handoff check"], quiet: true)
        do {
            let controlling: DesktopSession = try await api.decode("POST", "/surfaces/desktop/sessions/\(other.id)/control", json: ["action": "acquire"], quiet: true)
            let lease = try XCTUnwrap(controlling.controller)
            // Keep the competing controller alive even on a slow SSH reconnect.
            let renew = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    let _: DesktopSession = try await api.decode("POST", "/surfaces/desktop/sessions/\(other.id)/control",
                        json: ["action": "renew", "generation": lease.generation], quiet: true)
                }
            }
            defer { renew.cancel() }
            await model.resume()
            try await waitForDesktop(model)
            XCTAssertFalse(model.controlsDesktop, "Returning must never reclaim another controller's lease.")
            XCTAssertEqual(model.snapshot?.controller?.sessionId, other.id)
        } catch {
            _ = try? await api.run("DELETE", "/surfaces/desktop/sessions/\(other.id)", json: nil, quiet: true)
            throw error
        }
        _ = try await api.run("DELETE", "/surfaces/desktop/sessions/\(other.id)", json: nil, quiet: true)
        await model.takeControl()
        XCTAssertTrue(model.controlsDesktop)
        try await Task.sleep(for: .milliseconds(300))
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try screenshot.pngData()?.write(to: directory.appendingPathComponent("MindwireDesktopUXCheck.png"), options: .completeFileProtection)
        model.disconnect()
        await model.resume()
        XCTAssertFalse(model.connected, "Manual Disconnect must not auto-resume.")
        XCTAssertNil(model.image)
        if env["MINDWIRE_DESKTOP_DIAGNOSTICS"] == "1" { try? FileManager.default.removeItem(at: diagnosticFixture) }
        print("DESKTOP_UX_CHECK native frame, Mac session preparation, lease release and foreground resume passed")
        #endif
    }

    func testDesktopModelThroughWorkspaceProxy() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MINDWIRE_DESKTOP_CHECK"] == "1",
              let port = env["MINDWIRE_DESKTOP_DAEMON_PORT"].flatMap(Int.init),
              let daemonToken = env["MINDWIRE_DESKTOP_DAEMON_TOKEN"] else {
            throw XCTSkip("Opt in with an isolated daemon in the selected workspace.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Use the signed-in phone.")
        #else
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
        await OblienAuth.shared.refresh()
        XCTAssertTrue(OblienAuth.shared.authenticated)
        let workspaceId = try XCTUnwrap(env["MINDWIRE_DESKTOP_WORKSPACE"])
        let live = try await OblienCloud.client.workspaces.get(workspaceId)
        XCTAssertTrue(live.isRunning)
        let workspace = Workspace(id: workspaceId, name: live.name ?? "Desktop check",
            runtime: .cloud(workspaceId: workspaceId), createdAt: isoNow())
        let suite = "desktop-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let api = DaemonHTTP(channel: ProxyDaemonChannel(workspaceId: workspaceId, port: port, daemonToken: daemonToken), agentType: "")
        let coordinator = DaemonWorkCoordinator(defaults: defaults)
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: {
            WorkspaceRegistryClient(workspace: $0, stores: stores, http: api, coordinator: coordinator)
        }, resolveWorkspace: { $0 == workspaceId ? workspace : nil })
        let model = DesktopModel(workspace: workspace, stores: stores)
        defer { model.disconnect() }
        await model.connect()
        try await waitForDesktop(model)
        XCTAssertFalse(model.controlsDesktop, "Opening a viewer must not take control.")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        defer { try? FileManager.default.removeItem(at: directory.appendingPathComponent("MindwireDesktopFixture.json")) }
        let image = try XCTUnwrap(model.image)
        try UIImage(cgImage: image).pngData()?.write(to: directory.appendingPathComponent("MindwireDesktopCheck.png"), options: .completeFileProtection)
        print("DESKTOP_CHECK full app frame \(image.width)x\(image.height)")

        await model.takeControl()
        XCTAssertTrue(model.controlsDesktop, model.error ?? "Take control did not acquire the shared controller.")
        let controller = try XCTUnwrap(model.snapshot?.controller)
        model.send(.init(kind: "key", keys: ["Shift"]))
        await Task.yield()
        let inputDeadline = Date().addingTimeInterval(20)
        while model.inputBusy, Date() < inputDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(model.inputBusy)
        XCTAssertNil(model.error)
        let capture: DesktopCapture = try await api.decode("POST", "/surfaces/desktop/sessions/\(controller.sessionId)/captures", quiet: true)
        let artifact: DesktopArtifact = try await api.decode("GET", "/artifacts/\(capture.artifactId)", quiet: true)
        XCTAssertEqual(artifact.width, image.width)
        XCTAssertNotNil(UIImage(data: artifact.data))

        // Another viewer taking control must reconcile immediately and leave the
        // first viewer alive when its next heartbeat arrives with old state.
        let second: DesktopSession = try await api.decode("POST", "/surfaces/desktop/sessions",
            json: ["requestId": UUID().uuidString, "mode": "view", "name": "Desktop handoff check"], quiet: true)
        let _: DesktopSession = try await api.decode("POST", "/surfaces/desktop/sessions/\(second.id)/control",
            json: ["action": "takeover"], quiet: true)
        try await Task.sleep(for: .seconds(6))
        XCTAssertTrue(model.connected, model.error ?? "Handoff closed the viewer.")
        XCTAssertFalse(model.controlsDesktop, "Controller changes did not reconcile.")
        _ = try await api.run("DELETE", "/surfaces/desktop/sessions/\(second.id)", json: nil, quiet: true)
        await model.takeControl()
        XCTAssertTrue(model.controlsDesktop)
        await model.releaseControl()
        XCTAssertFalse(model.controlsDesktop)
        XCTAssertTrue(model.connected)

        model.disconnect()
        XCTAssertNil(model.image)
        await model.connect()
        try await waitForDesktop(model)
        XCTAssertFalse(model.controlsDesktop)
        print("DESKTOP_CHECK full app control, input, artifact, handoff and reconnect passed")
        #endif
    }

    private func waitForDesktop(_ model: DesktopModel) async throws {
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, model.error == nil {
            if model.connected, let image = model.image, Self.hasPixels(image) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(model.error ?? "The native desktop did not deliver pixels.")
        throw DesktopProblem(code: "test_connection", message: "Desktop connection check failed.")
    }

    private static func hasPixels(_ image: CGImage) -> Bool {
        guard let pixels = image.dataProvider?.data as Data?, pixels.count >= 4 else { return false }
        return stride(from: 0, to: pixels.count - 3, by: 4).contains { pixels[$0] != 0 || pixels[$0+1] != 0 || pixels[$0+2] != 0 }
    }

    func testProviderDiscoveryOnSignedInDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MINDWIRE_DESKTOP_CHECK"] == "1" else {
            throw XCTSkip("Opt in on a signed-in physical device.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Use the signed-in phone.")
        #else
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
        await OblienAuth.shared.refresh()
        XCTAssertTrue(OblienAuth.shared.authenticated, "The device must be signed in.")
        let chosen = try XCTUnwrap(env["MINDWIRE_DESKTOP_WORKSPACE"])
        let list = try await OblienCloud.client.workspaces.list()
        let workspace = try XCTUnwrap(list.workspaces.first { $0.id == chosen || $0.name == chosen }, "Selected workspace must exist.")
        XCTAssertTrue(workspace.isRunning, "Selected workspace must be running.")
        let provider = CloudDesktopProvider(workspaceId: workspace.id)
        var status = try await provider.status()
        XCTAssertTrue(status.supported, "Selected workspace must support desktop access.")
        print("DESKTOP_CHECK selected=\(workspace.id) supported=\(status.supported) enabled=\(status.enabled) available=\(status.available)")
        var fixture: [String: Any] = ["workspaceId": workspace.id, "token": try await provider.gatewayToken(),
            "baseURL": OblienCloud.client.config.runtimeURL.absoluteString]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if env["MINDWIRE_DESKTOP_CONNECT"] == "1" {
            if !status.enabled { try await provider.enable() }
            let deadline = Date().addingTimeInterval(45)
            while !status.available, Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                status = try await provider.status()
            }
            XCTAssertTrue(status.available, "The display must become available after enabling it.")
            let grant = try await provider.connection()
            fixture["connection"] = try grant.desktopJSON()
            // Copy only scoped credentials through the trusted device container.
            try JSONSerialization.data(withJSONObject: fixture).write(to: directory.appendingPathComponent("MindwireDesktopFixture.json"),
                options: [.atomic, .completeFileProtection])
            print("DESKTOP_CHECK scoped fixture saved privately")

            let connection = SSHConnection(host: grant.ssh.host, port: grant.ssh.port, username: grant.ssh.username,
                auth: .password(grant.ssh.password), expectedHostKey: grant.ssh.host_key_fingerprint)
            defer { connection.close() }
            let tunnel = try await connection.forwardLocal(host: grant.vnc.host, port: grant.vnc.port)
            defer { tunnel.close() }
            let viewer = NativeDesktopConnection()
            defer { viewer.disconnect() }
            let firstFrame = expectation(description: "Native VNC displays the workspace through pinned SSH")
            var captured = false
            viewer.onFrame = { frame in
                let image = frame.image
                guard !captured, image.width > 0, image.height > 0 else { return }
                guard Self.hasPixels(image) else { return }
                captured = true
                try? UIImage(cgImage: image).pngData()?.write(to: directory.appendingPathComponent("MindwireDesktopCheck.png"), options: .completeFileProtection)
                print("DESKTOP_CHECK native frame \(image.width)x\(image.height)")
                firstFrame.fulfill()
            }
            viewer.onState = { ready, message in
                if !ready && !captured { captured = true; XCTFail(message ?? "Native connection closed before its first frame."); firstFrame.fulfill() }
            }
            viewer.connect(port: tunnel.port)
            await fulfillment(of: [firstFrame], timeout: 40)
        }
        #endif
    }
}

final class DesktopCheckAdapter: WorkspaceAdapter {
    let workspace: Workspace
    init(_ workspace: Workspace) { self.workspace = workspace }
    func owns(_ workspace: Workspace) -> Bool { workspace.id == self.workspace.id }
    func current() -> [Workspace] { [workspace] }
    func refresh() async throws {}
    func adopt(name: String, runtime: AgentRuntime, spec: WorkspaceSpec?) async -> Workspace? { nil }
    func rename(_ id: String, to name: String) async {}
    func delete(_ id: String) async throws {}
}
