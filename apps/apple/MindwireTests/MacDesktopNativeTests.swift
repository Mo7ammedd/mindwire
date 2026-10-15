import XCTest
import SwiftUI
@testable import Mindwire

/// Uses the production pairing, pooled SSH, desktop model and native VNC viewer.
/// The synthetic fixture never touches a real screen. Live use requires an
/// explicit invitation from the owner's separately configured test daemon.
@MainActor
final class MacDesktopNativeTests: XCTestCase {
    private struct Fixture: Decodable {
        let invitations: [ComputerInvitation]
        var live: Bool? = nil
    }
    private struct State: Decodable {
        let sessions: Int; let viewers: Int; let keyPresses: Int
        let formats16: Int; let formats24: Int
        let pointerEvents: [[Int]]
    }

    func testPairedMacDesktopSetupControlAndReconnect() async throws {
        guard let file = ProcessInfo.processInfo.environment["MINDWIRE_MAC_DESKTOP_FIXTURE"] else {
            throw XCTSkip("Requires the isolated Mac desktop fixture.")
        }
        var fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let live = fixture.live == true
        let performance = live && ProcessInfo.processInfo.environment["MINDWIRE_MAC_DESKTOP_PERFORMANCE"] == "1"
        if live, fixture.invitations.isEmpty {
            // Issue the short-lived invitation after Xcode launches the app;
            // simulator startup must not consume its pairing lifetime.
            try Data().write(to: URL(fileURLWithPath: file + ".ready-for-pairing"))
            try await wait("fresh Mac pairing invitation", timeout: 20) {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
                      let fresh = try? JSONDecoder().decode(Fixture.self, from: data),
                      !fresh.invitations.isEmpty else { return false }
                fixture = fresh
                return true
            }
        }
        var phase = "pairing"
        defer { if live { print("Mac desktop live test ended at: \(phase)") } }
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }

        for invitation in fixture.invitations {
            let suite = "mac-desktop-native-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let stores = Stores(defaults: defaults)
            let code = String(decoding: try JSONEncoder().encode(invitation), as: UTF8.self)
            let original = try await ComputerPairingService.pair(code, deviceName: "Mindwire desktop test iPhone", stores: stores) { _ in }
            var computer = original.computer
            computer.routes = invitation.routes
            let paired = ComputerPairingService.Result(invitation: original.invitation, computer: computer,
                host: original.host, health: original.health, pairingRequestId: original.pairingRequestId)
            let connection = stores.savePairedComputer(paired, name: "My Mac")
            defer { stores.deleteServer(connection.id); defaults.removePersistentDomain(forName: suite) }
            let channel = ComputerDaemonChannel(computer: paired.computer, stores: stores)
            let api = DaemonHTTP(channel: channel, agentType: "")
            let workspace = try XCTUnwrap(stores.workspaces(forServerId: connection.id).first)
            if !live || performance {
                stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in DesktopNativeFixtureRemote(api: api) })
            }
            let repository = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores)])
            let model = try XCTUnwrap(repository.desktopModel(for: workspace.id))
            defer {
                if live { print("Mac desktop state: stage=\(model.stage) connected=\(model.connected) frame=\(model.image != nil) error=\(model.error ?? "none")") }
                model.disconnect()
            }

            phase = "status"
            await model.load()
            XCTAssertNil(model.error)
            XCTAssertTrue(model.usesLocalSetup)
            if !live {
                XCTAssertTrue(model.needsLocalSetup)
                try await captureSetup(workspace: workspace, repository: repository, stores: stores, file: file + ".setup.png")
                _ = try await api.run("POST", "/fixture/enable", json: [:], quiet: true)
                await model.load(force: true)
            }
            XCTAssertFalse(model.needsLocalSetup)
            phase = "connecting"
            let started = Date()
            async let first: Void = model.connect(automaticallyControl: !performance)
            async let second: Void = model.connect(automaticallyControl: !performance)
            _ = await (first, second)
            phase = "first frame"
            try await wait("native display", timeout: 25) { model.connected && model.image != nil }
            XCTAssertNil(model.error)
            let frame = try XCTUnwrap(model.image)
            if live {
                XCTAssertGreaterThan(frame.width, 400)
                XCTAssertGreaterThan(frame.height, 300)
            } else {
                XCTAssertEqual(frame.width, 1536)
                XCTAssertEqual(frame.height, 1024)
                let pixels = try XCTUnwrap(frame.dataProvider?.data as Data?)
                for (actual, expected) in zip(pixels.prefix(3), [40, 30, 200]) {
                    XCTAssertLessThanOrEqual(abs(Int(actual) - expected), 8, "Reduced color must still decode correctly")
                }
                XCTAssertEqual(Array(pixels.suffix(4).prefix(3)), Array(pixels.prefix(3)), "The full large frame crossed SSH backpressure")
                let state: State = try await api.decode("GET", "/fixture/state", quiet: true)
                XCTAssertEqual(state.sessions, 1, "Repeated connect must share the same session")
                XCTAssertEqual(state.viewers, 1)
                XCTAssertGreaterThan(state.formats16, 0, "Balanced quality must negotiate fewer wire bits")
            }
            if performance {
                let firstFrame = Date().timeIntervalSince(started)
                let until = Date().addingTimeInterval(8)
                var previous = model.image
                var updates = 0
                while Date() < until {
                    try await Task.sleep(for: .milliseconds(5))
                    if model.image !== previous { updates += 1; previous = model.image }
                }
                print("MAC_DISPLAY_PERFORMANCE route=\(invitation.routes.first?.kind ?? "unknown") size=\(frame.width)x\(frame.height) firstFrame=\(firstFrame)s presented=\(updates) in=8s")
                XCTAssertTrue(model.connected)
                XCTAssertNil(model.error)
                XCTAssertFalse(model.controlsDesktop)
                let source = model.displaySize
                for quality in [DesktopStreamQuality.dataSaver, .original, .balanced] {
                    model.configureStream(.init(quality: quality, framesPerSecond: quality == .dataSaver ? 15 : 30))
                    let expected = quality.imageSize(for: source)
                    try await wait("live \(quality.title) stream", timeout: 20) {
                        !model.changingStream && model.image?.width == Int(expected.width) && model.image?.height == Int(expected.height)
                    }
                    XCTAssertEqual(model.displaySize, source)
                    XCTAssertFalse(model.controlsDesktop)
                    XCTAssertNil(model.error)
                    print("MAC_STREAM_QUALITY route=\(invitation.routes.first?.kind ?? "unknown") quality=\(quality.rawValue) pixels=\(Int(expected.width))x\(Int(expected.height))")
                }
                continue // Never take control or send input in a performance run.
            }
            try await wait("automatic mouse control") { model.controlsDesktop }
            phase = "control"
            XCTAssertTrue(model.controlsDesktop)

            if !live {
                if invitation.routes.first?.kind == "ssh" { try await captureControls(model: model, file: file) }
                let controller = try XCTUnwrap(model.snapshot?.controller)
                let previousFrame = model.image
                model.configureStream(.init(quality: .dataSaver, framesPerSecond: 15))
                XCTAssertTrue(model.controlsDesktop)
                XCTAssertTrue(model.image === previousFrame, "Keep the current image while changing quality")
                try await wait("reduced native image", timeout: 15) { !model.changingStream && model.image?.width == 1280 }
                XCTAssertEqual(model.displaySize, CGSize(width: 1536, height: 1024), "Input must retain original desktop coordinates")
                model.configureStream(.init(quality: .original, framesPerSecond: 60))
                try await wait("original native image", timeout: 15) { !model.changingStream && model.image?.width == 1536 }
                XCTAssertEqual(model.snapshot?.controller?.sessionId, controller.sessionId)
                XCTAssertEqual(model.snapshot?.controller?.generation, controller.generation, "Stream options must preserve the same control generation")
                let state: State = try await api.decode("GET", "/fixture/state", quiet: true)
                XCTAssertEqual(state.sessions, 1)
                XCTAssertEqual(state.viewers, 1)
                XCTAssertGreaterThan(state.formats24, 0)
                try await verifyTouchpadInput(model: model, api: api)
            }

            if live {
                // The host runner focuses a disposable input window before
                // authorizing any real keystroke. Never type into an unknown app.
                try Data().write(to: URL(fileURLWithPath: file + ".ready-for-input"))
                phase = "input window"
                try await wait("disposable Mac input window", timeout: 180) {
                    FileManager.default.fileExists(atPath: file + ".allow-input") && self.hostInputTargetIsFocused(file)
                }
                struct InputTarget: Decodable { let x: Int; let y: Int }
                let target = try JSONDecoder().decode(InputTarget.self, from: Data(contentsOf: URL(fileURLWithPath: file + ".pointer.json")))
                phase = "pointer"
                model.send(.init(kind: "click", x: target.x, y: target.y, button: "left"))
                try await wait("Mac received the click", timeout: 12) {
                    FileManager.default.fileExists(atPath: file + ".pointer-verified")
                }
                guard hostInputTargetIsFocused(file) else {
                    throw DesktopProblem(code: "test_focus_lost", message: "The disposable Mac input window lost focus; no text was sent.")
                }
                model.type("Mindwire desktop test")
                phase = "typing"
                await Task.yield()
                try await wait("input completion") { !model.inputBusy }
                try Data().write(to: URL(fileURLWithPath: file + ".input-sent"))
                try await wait("Mac received the text", timeout: 12) {
                    FileManager.default.fileExists(atPath: file + ".input-verified")
                }
            } else {
                let before: State = try await api.decode("GET", "/fixture/state", quiet: true)
                model.type("test")
                await Task.yield()
                try await wait("input completion") { !model.inputBusy }
                let state: State = try await api.decode("GET", "/fixture/state", quiet: true)
                XCTAssertEqual(state.keyPresses - before.keyPresses, 4, "Exactly the four typed keys")
                _ = try await api.run("POST", "/fixture/drop-video", json: [:], quiet: true)
                try await wait("retry starts") { !model.connected }
                try await wait("display reconnects", timeout: 15) { model.connected && !model.reconnecting }
                try await wait("reconnect restores requested control") { model.controlsDesktop }
                let after: State = try await api.decode("GET", "/fixture/state", quiet: true)
                XCTAssertEqual(after.keyPresses, state.keyPresses, "Reconnect must never replay input")
            }
            let healthy: DaemonHealth = try await api.decode("GET", "/healthz", quiet: true)
            XCTAssertTrue(healthy.ok)

            model.suspend()
            phase = "foreground resume"
            XCTAssertFalse(model.connected)
            XCTAssertNotNil(model.image, "Keep the last frame while returning from background")
            await model.resume()
            try await wait("foreground resume", timeout: 25) { model.connected && model.image != nil }
            try await wait("foreground restores requested control") { model.controlsDesktop }
            if !live {
                await model.releaseControl()
                XCTAssertFalse(model.controlsDesktop)
                model.suspend()
                await model.resume()
                try await wait("view-only resume", timeout: 15) { model.connected && model.image != nil }
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertFalse(model.controlsDesktop, "Explicit Release must remain view-only on resume")
                _ = try await api.run("POST", "/fixture/disable", json: [:], quiet: true)
                try await wait("local disable reaches the phone", timeout: 15) { model.needsLocalSetup && !model.reconnecting && !model.busy }
                XCTAssertFalse(model.connected)
            }
            model.disconnect()
            let afterClose: DaemonHealth = try await api.decode("GET", "/healthz", quiet: true)
            XCTAssertTrue(afterClose.ok, "Desktop cleanup must preserve the existing workspace connection")
            await channel.close()
            phase = "completed"
        }
        try Data().write(to: URL(fileURLWithPath: file + ".done"))
    }

    private func wait(_ label: String, timeout: TimeInterval = 8, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(40)) }
        guard condition() else { throw DesktopProblem(code: "test_timeout", message: "Timed out: \(label)") }
    }

    private func captureControls(model: DesktopModel, file: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        let layouts: [(String, CGSize, DesktopPointerMode, Bool)] = [
            ("touchpad", CGSize(width: 390, height: 590), .touchpad, false),
            ("landscape", CGSize(width: 844, height: 260), .touchpad, false),
            ("keyboard", CGSize(width: 390, height: 270), .stick, false),
            ("keyboard-landscape", CGSize(width: 844, height: 112), .stick, false),
            ("fullscreen", CGSize(width: 844, height: 360), .screen, true),
            ("fullscreen-stick", CGSize(width: 844, height: 360), .stick, true)
        ]
        for (name, size, mode, fullscreen) in layouts {
            let view = DesktopStreamContent(model: model, alignTop: true, mode: mode, fullscreen: fullscreen,
                pointerSensitivity: 1, pointer: DesktopCursor())
                .frame(width: size.width, height: size.height).background(Color.black)
                .preferredColorScheme(.dark).ignoresSafeArea()
            let controller = UIHostingController(rootView: view)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: file + "." + name + ".png"))
        }
    }

    private func verifyTouchpadInput(model: DesktopModel, api: DaemonHTTP) async throws {
        let pointer = DesktopCursor()
        let size = model.displaySize
        pointer.place(at: CGPoint(x: 120, y: 90), pixels: size)
        pointer.handle(.button(true), pixels: size, send: model.send)
        await Task.yield()
        try await wait("native mouse-down") { !model.inputBusy }
        pointer.handle(.move(CGSize(width: 40, height: 20)), pixels: size, send: model.send)
        await Task.yield()
        try await wait("native held drag") { !model.inputBusy }
        pointer.handle(.button(false), pixels: size, send: model.send)
        pointer.handle(.move(CGSize(width: 20, height: 0)), pixels: size, send: model.send)
        await Task.yield()
        try await wait("native mouse-up") { !model.inputBusy }
        XCTAssertNil(model.error)
        let state: State = try await api.decode("GET", "/fixture/state", quiet: true)
        XCTAssertEqual(Array(state.pointerEvents.suffix(4)), [[1, 120, 90], [1, 160, 110], [0, 160, 110], [0, 180, 110]],
                       "Press, held movement, release and the next stroke must reach RFB in order at their original coordinates")
    }

    private func hostInputTargetIsFocused(_ file: String) -> Bool {
        struct Focus: Decodable { let active: Bool }
        let path = file + ".current-state.json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 1,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let state = try? JSONDecoder().decode(Focus.self, from: data) else { return false }
        return state.active
    }

    private func captureSetup(workspace: Workspace, repository: WorkspaceRepository, stores: Stores, file: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let screen = UIHostingController(rootView: DesktopScreen(workspaceId: workspace.id, repository: repository)
            .environment(\.stores, stores).preferredColorScheme(.dark))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(300))
        screen.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Mac desktop setup"; attachment.lifetime = .keepAlways
        add(attachment)
        #if targetEnvironment(simulator)
        try image.pngData()?.write(to: URL(fileURLWithPath: file))
        #endif
    }
}

@MainActor
final class DesktopNativeFixtureRemote: WorkspaceRegistryRemote {
    let api: DaemonHTTP
    init(api: DaemonHTTP) { self.api = api }
    func desktopHTTP() async throws -> DaemonHTTP { api }
    func desktopCatalogHTTP() async throws -> DaemonHTTP { api }
    func prepare(allowInstall: Bool) async throws {}
    func dispose() async {}
    func snapshot() async throws -> WorkspaceMetadata { throw WorkspaceRegistryError.missing }
    func changes(since: Int64, identity: String) async throws -> WorkspaceMetadata { throw WorkspaceRegistryError.missing }
    func importLegacy(_ records: WorkspaceLegacyImport) async throws -> WorkspaceMetadata { throw WorkspaceRegistryError.missing }
    func put(kind: String, id: String, record: Data, revision: Int64?) async throws -> WorkspaceMetadata { throw WorkspaceRegistryError.missing }
    func delete(kind: String, id: String, revision: Int64?) async throws -> WorkspaceMetadata { throw WorkspaceRegistryError.missing }
}
