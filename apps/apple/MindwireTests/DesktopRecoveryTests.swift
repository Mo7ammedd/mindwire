import XCTest
import UIKit
import Observation
import SwiftUI
@testable import Mindwire

@MainActor
final class DesktopRecoveryTests: XCTestCase {
    func testRecoveryGraceBelongsToOutageNotIndividualAttempts() {
        var recovery = DesktopRecovery()
        XCTAssertTrue(recovery.begin(at: 100))
        for time in [101.0, 103, 107] {
            XCTAssertFalse(recovery.begin(at: time))
            recovery.advance(to: time)
            XCTAssertFalse(recovery.timedOut)
        }
        recovery.advance(to: 110)
        XCTAssertTrue(recovery.timedOut)
        recovery.finish()
        XCTAssertFalse(recovery.active)
        XCTAssertFalse(recovery.timedOut)
        XCTAssertTrue(recovery.begin(at: 200))
        recovery.advance(to: 201)
        XCTAssertFalse(recovery.timedOut, "A new interruption gets its own grace period.")
    }

    func testDelayedOldPixelsCannotConfirmAnInputAndContinuousFramesRetireOlderActions() {
        var progress = DesktopInputProgress()
        progress.began(at: 10)
        progress.acknowledged(at: 10.1, changesDisplay: true)
        progress.displayed(requestedAt: 9.9)
        XCTAssertTrue(progress.stalled(at: 10.8), "Decoding an old frame later does not acknowledge the click.")
        progress.began(at: 10.8)
        progress.acknowledged(at: 10.9, changesDisplay: true)
        progress.displayed(requestedAt: 10.2)
        XCTAssertFalse(progress.stalled(at: 11), "A continuous gesture retires each observed action independently.")
        XCTAssertTrue(progress.pending)
        progress.displayed(requestedAt: 11.1)
        XCTAssertFalse(progress.pending)
    }

    func testOrdinaryMouseMotionOnlyWaitsForDispatchNotARepaint() {
        var progress = DesktopInputProgress()
        progress.began(at: 1)
        XCTAssertFalse(progress.stalled(at: 1.2))
        progress.acknowledged(at: 1.2, changesDisplay: DesktopInput(kind: "pointer", buttons: 0).changesDisplay)
        XCTAssertFalse(progress.pending, "A static screen must not freeze the local mouse.")
        XCTAssertTrue(DesktopInput(kind: "pointer", buttons: 1).changesDisplay)
        XCTAssertTrue(DesktopInput(kind: "click").changesDisplay)
    }

    func testInitialConnectionKeepsFullPanelUntilTheFirstFrame() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        fixture.viewers.holdsFrames = true
        XCTAssertTrue(fixture.model.showsConnectionOverlay)
        XCTAssertFalse(fixture.model.showsConnectionIndicator)
        await fixture.model.connect()
        try await wait { fixture.model.connected }
        XCTAssertTrue(fixture.model.showsInitialConnectionProgress)
        XCTAssertTrue(fixture.model.showsConnectionOverlay, "First opening keeps the full connection panel")
        XCTAssertFalse(fixture.model.showsConnectionIndicator, "Do not duplicate startup with a top indicator")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: DesktopScreen(workspaceId: fixture.model.workspace.id,
            desktopName: "Desktop", initialModel: fixture.model).preferredColorScheme(.dark))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(100))
        capture(window, name: "desktop-initial-connection-panel")

        fixture.viewers.all[0].frame()
        XCTAssertFalse(fixture.model.showsConnectionOverlay)
        XCTAssertFalse(fixture.model.showsInitialConnectionProgress)
        try await wait { fixture.model.acceptsInput }
        await fixture.channel.delayNextAction(1)
        fixture.model.send(.init(kind: "key", keys: ["a"]))
        try await wait { fixture.model.inputSynchronizing }
        capture(window, name: "desktop-active-input-indicator")
        XCTAssertFalse(fixture.model.showsConnectionOverlay)
        XCTAssertTrue(fixture.model.canMovePointer)
    }

    func testCloudDropRetainsScreenAndControlsThenReconnectsOnlyOnce() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.controlsDesktop }
        let image = fixture.model.image
        fixture.viewers.all[0].onState?(false, "test outage")
        XCTAssertTrue(fixture.model.reconnecting)
        XCTAssertTrue(fixture.model.recovery.active)
        XCTAssertFalse(fixture.model.showsConnectionOverlay)
        XCTAssertTrue(fixture.model.showsConnectionIndicator)
        XCTAssertTrue(fixture.model.image === image)
        XCTAssertTrue(fixture.model.keepsControlLayout)
        XCTAssertFalse(fixture.model.acceptsInput)
        XCTAssertTrue(fixture.model.canMovePointer)
        let before = fixture.model.cursor.normalized
        fixture.model.handlePointer(.move(CGSize(width: 1, height: 0)))
        XCTAssertNotEqual(fixture.model.cursor.normalized, before, "Local movement survives a transport reset")
        try await wait { fixture.viewers.all.count == 2 && fixture.model.controlsDesktop }
        XCTAssertFalse(fixture.model.recovery.active)
        XCTAssertFalse(fixture.model.showsConnectionOverlay)
        let opens = await fixture.channel.openCount
        XCTAssertEqual(opens, 2)
        fixture.viewers.all[0].onState?(false, "late old callback")
        XCTAssertTrue(fixture.model.connected)
        XCTAssertEqual(fixture.viewers.all.count, 2)
    }

    func testOneFailedHeartbeatDoesNotCloseViewerOrResetControlLayout() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.controlsDesktop }
        await fixture.channel.failNextHeartbeat()
        try await wait(timeout: 7) { !fixture.model.controlReachable }
        XCTAssertTrue(fixture.model.connected)
        XCTAssertTrue(fixture.model.keepsControlLayout)
        XCTAssertTrue(fixture.model.acceptsInput, "One lost heartbeat must not freeze a still-authorized input queue")
        XCTAssertTrue(fixture.model.showsConnectionIndicator)
        XCTAssertFalse(fixture.model.showsConnectionOverlay)
        XCTAssertEqual(fixture.viewers.all.count, 1)
        try await wait { fixture.model.controlReachable }
        XCTAssertFalse(fixture.model.recovery.active)
        XCTAssertEqual(fixture.viewers.all.count, 1)
        let opens = await fixture.channel.openCount
        XCTAssertEqual(opens, 1)
    }

    func testReconnectedControlWaitsForFreshPixelsBeforeAcceptingClicks() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.acceptsInput }
        fixture.viewers.holdsFrames = true
        fixture.viewers.all[0].onState?(false, "brief outage")
        try await wait { fixture.viewers.all.count == 2 && fixture.model.controlsDesktop }
        XCTAssertTrue(fixture.model.hasFrame, "Keep showing the last good image during reconnect.")
        XCTAssertTrue(fixture.model.keepsControlLayout)
        XCTAssertFalse(fixture.model.acceptsInput, "A retained old image cannot unlock input on the new connection.")
        fixture.model.send(.init(kind: "click", x: 1, y: 1))
        let inputs = await fixture.channel.inputs
        XCTAssertTrue(inputs.isEmpty)
        fixture.model.send(.init(kind: "pointer", x: 3, y: 2, buttons: 0))
        try await wait { await fixture.channel.inputs.count == 1 }
        let release = await fixture.channel.inputs.first
        XCTAssertEqual(release, .init(kind: "release"), "A late hover can release buttons, but cannot move on stale pixels.")
        fixture.viewers.all[1].frame()
        XCTAssertTrue(fixture.model.acceptsInput)
    }

    func testSlowMouseDownQueuesDragClickAndTypingWithoutFreezingTheLocalCursor() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.controlsDesktop }
        let canvas = DesktopCanvasView()
        canvas.cursor = fixture.model.cursor
        fixture.model.cursor.place(at: CGPoint(x: 1, y: 1), pixels: fixture.model.displaySize)
        await fixture.channel.delayNextAction(1.0)
        fixture.model.handlePointer(.button(true))
        try await wait { await fixture.channel.inputs.count == 1 }
        fixture.model.handlePointer(.move(CGSize(width: 1, height: 0)))
        try await wait { fixture.model.inputSynchronizing }
        XCTAssertTrue(fixture.model.acceptsInput)
        XCTAssertTrue(fixture.model.canMovePointer)
        XCTAssertTrue(fixture.model.showsConnectionIndicator)
        XCTAssertFalse(fixture.model.showsConnectionOverlay)
        fixture.model.handlePointer(.move(CGSize(width: 1, height: 1)))
        XCTAssertEqual(canvas.pointer, CGPoint(x: 0.75, y: 2.0 / 3.0), "The cursor moves before the blocked network action finishes")
        fixture.model.handlePointer(.button(false))
        fixture.model.handlePointer(.click("left", 1))
        fixture.model.handlePointer(.move(CGSize(width: -2, height: -1)))
        fixture.model.type("ab")
        XCTAssertEqual(canvas.pointer?.x, 0.25)
        try await wait { !fixture.model.inputBusy && !fixture.model.inputSynchronizing }
        let inputs = await fixture.channel.inputs
        XCTAssertEqual(inputs, [
            .init(kind: "pointer", x: 1, y: 1, buttons: 1),
            .init(kind: "pointer", x: 3, y: 2, buttons: 1),
            .init(kind: "pointer", x: 3, y: 2, buttons: 0),
            .init(kind: "click", x: 3, y: 2, button: "left", count: 1),
            .init(kind: "pointer", x: 1, y: 1, buttons: 0),
            .init(kind: "key", keys: ["a"]), .init(kind: "key", keys: ["b"])
        ], "Only pending motion coalesces; later movement never retargets the click")
        XCTAssertTrue(fixture.model.acceptsInput)
        XCTAssertNil(fixture.model.error)
        XCTAssertGreaterThan(fixture.viewers.all[0].refreshes, 0)
    }

    func testVideoDelayRefreshesViewerWithoutReplacingControlOrDroppingInput() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.acceptsInput }
        fixture.viewers.all[0].holdsFrames = true
        fixture.model.send(.init(kind: "key", keys: ["a"]))
        try await wait { fixture.model.inputSynchronizing }
        fixture.model.send(.init(kind: "key", keys: ["b"]))
        try await wait { await fixture.channel.inputs.count == 2 }
        XCTAssertTrue(fixture.model.acceptsInput)
        XCTAssertFalse(fixture.model.showsConnectionOverlay)
        try await wait(timeout: 6) { fixture.viewers.all.count == 2 && !fixture.model.inputSynchronizing }
        let opens = await fixture.channel.openCount
        XCTAssertEqual(opens, 1, "A delayed video stream does not reset the input session")
        let inputs = await fixture.channel.inputs
        XCTAssertEqual(inputs.map(\.keys), [["a"], ["b"]])
        XCTAssertTrue(fixture.model.acceptsInput)
        XCTAssertNil(fixture.model.error)
    }

    func testQueueBackpressureNeverErasesAlreadyAcceptedTyping() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.acceptsInput }
        await fixture.channel.delayNextAction(0.3)
        fixture.model.send(.init(kind: "key", keys: ["Enter"]))
        try await wait { await fixture.channel.inputs.count == 1 }
        for _ in 0..<(DesktopInputBuffer.capacity - 1) { fixture.model.send(.init(kind: "key", keys: ["a"])) }
        fixture.model.send(.init(kind: "key", keys: ["b"]))
        try await wait { !fixture.model.inputBusy }
        let inputs = await fixture.channel.inputs
        XCTAssertEqual(inputs.count, DesktopInputBuffer.capacity)
        XCTAssertEqual(inputs.first?.keys, ["Enter"])
        XCTAssertTrue(inputs.dropFirst().allSatisfy { $0.keys == ["a"] })
        XCTAssertNotNil(fixture.model.error, "Report rejected overflow instead of dropping accepted input")
    }

    func testStaticDesktopConfirmsInputBeforeShowingDelay() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.acceptsInput }
        let paused = expectation(description: "A static screen confirms input before the delay indicator")
        paused.isInverted = true
        withObservationTracking { _ = fixture.model.inputSynchronizing } onChange: { paused.fulfill() }
        fixture.model.send(.init(kind: "key", keys: ["Escape"]))
        try await wait(timeout: 0.6) { fixture.viewers.all[0].refreshes > 0 }
        fixture.model.send(.init(kind: "key", keys: ["a"]))
        try await wait { await fixture.channel.inputs.count == 2 && !fixture.model.inputBusy }
        await fulfillment(of: [paused], timeout: 0.8)
        XCTAssertNil(fixture.model.error)
        XCTAssertTrue(fixture.model.acceptsInput)
    }

    func testFrameConfirmationProbeOnlyWakesUnconfirmedBatches() {
        var progress = DesktopInputProgress()
        progress.began(at: 1)
        progress.acknowledged(at: 1.1, changesDisplay: true)
        XCTAssertFalse(progress.needsRefresh(at: 1.2))
        XCTAssertTrue(progress.needsRefresh(at: 1.3))
        XCTAssertFalse(progress.needsRefresh(at: 1.4), "One probe per unconfirmed batch")
        progress.displayed(requestedAt: 1.35)
        XCTAssertFalse(progress.needsRefresh(at: 2))
        progress.began(at: 2)
        progress.acknowledged(at: 2.1, changesDisplay: true)
        progress.displayed(requestedAt: 2.15)
        XCTAssertFalse(progress.needsRefresh(at: 2.3), "Normal streaming must not add a full refresh")
    }

    func testUncertainClickIsNeverReplayedOnReconnect() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.controlsDesktop }
        await fixture.channel.failNextActionAfterDispatch()
        fixture.model.send(.init(kind: "click", x: 1, y: 1))
        try await wait { fixture.viewers.all.count == 2 && fixture.model.controlsDesktop }
        let inputs = await fixture.channel.inputs
        XCTAssertEqual(inputs.filter { $0.kind == "click" }.count, 1)
        XCTAssertEqual(inputs.last?.kind, "release")
    }

    func testRemoteCursorShapeAndPressedStateSurviveCanvasReplacement() throws {
        let cursor = DesktopCursor()
        let first = DesktopCanvasView(), replacement = DesktopCanvasView()
        first.cursor = cursor
        let image = testImage()
        cursor.show(.init(image: image, hotspot: CGPoint(x: 1, y: 2)))
        cursor.handle(.button(true), pixels: CGSize(width: 4, height: 3)) { _ in }
        replacement.cursor = cursor
        first.cursor = nil
        XCTAssertTrue(replacement.cursorPressed)
        XCTAssertEqual(replacement.pointer, cursor.normalized)
        XCTAssertEqual(cursor.shape?.hotspot, CGPoint(x: 1, y: 2))
        cursor.release(pixels: CGSize(width: 4, height: 3)) { _ in }
        XCTAssertFalse(replacement.cursorPressed)
        XCTAssertTrue(cursor.shape?.image === image)
    }

    func testRemoteCursorDecodingChecksDimensionsAndHotspotBeforeRendering() throws {
        let image = testImage()
        let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
        func remote(width: Int? = nil, x: Int = 1, bytes: Data? = nil) -> DesktopRemoteCursor {
            .init(id: "text", width: width ?? image.width, height: image.height, hotspotX: x, hotspotY: 2, png: bytes ?? data)
        }
        let shape = try XCTUnwrap(DesktopCursorShape(remote: remote()))
        XCTAssertEqual(shape.image.width, image.width)
        XCTAssertEqual(shape.hotspot, CGPoint(x: 1, y: 2))
        XCTAssertNil(DesktopCursorShape(remote: remote(width: 257)))
        XCTAssertNil(DesktopCursorShape(remote: remote(width: 1)))
        XCTAssertNil(DesktopCursorShape(remote: remote(x: image.width)))
        XCTAssertNil(DesktopCursorShape(remote: remote(bytes: Data("not an image".utf8))))
    }

    func testVideoFramesDoNotInvalidateTheConnectionControls() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.controlsDesktop && fixture.model.hasFrame }
        let invalidated = expectation(description: "Streaming must not redraw connection controls")
        invalidated.isInverted = true
        withObservationTracking {
            _ = fixture.model.hasFrame
            _ = fixture.model.recovery.active
            _ = fixture.model.controlsDesktop
            _ = fixture.model.keepsControlLayout
        } onChange: { invalidated.fulfill() }
        for _ in 0..<30 { fixture.viewers.all[0].frame() }
        await fulfillment(of: [invalidated], timeout: 0.05)
    }

    func testLongPasteIsNotPartiallyDroppedByTheBoundedInputQueue() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { fixture.model.controlsDesktop }
        let text = String(repeating: "one line\n", count: 40)
        fixture.model.type(text)
        try await wait { await fixture.channel.inputs.count == 1 }
        let inputs = await fixture.channel.inputs
        XCTAssertEqual(inputs, [.init(kind: "text", text: text)])
        XCTAssertNil(fixture.model.error)
    }

    func testDroppedCursorEventsReconnectWithoutReplacingTheViewer() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait { await fixture.channel.streamOpens == 1 }
        await fixture.channel.closeEvents()
        try await wait { await fixture.channel.streamOpens == 2 }
        XCTAssertEqual(fixture.viewers.all.count, 1)
        XCTAssertFalse(fixture.model.recovery.active)
        XCTAssertTrue(fixture.model.controlsDesktop)
    }

    func testCursorEventsUpdateNativeCursorWithoutRedrawingControlsOrAcceptingOldState() async throws {
        let fixture = try fixture()
        defer { fixture.model.disconnect() }
        await fixture.model.connect()
        try await wait {
            let watching = await fixture.channel.watching
            return fixture.model.controlsDesktop && watching
        }
        let before = fixture.model.snapshot
        let source = testImage()
        let data = try XCTUnwrap(UIImage(cgImage: source).pngData())
        let remote = DesktopRemoteCursor(id: "text", width: source.width, height: source.height, hotspotX: 1, hotspotY: 2, png: data)
        try await fixture.channel.emitCursor(remote)
        try await wait { fixture.model.cursor.shape != nil }
        XCTAssertEqual(fixture.model.snapshot, before, "Cursor animations must not invalidate the surrounding SwiftUI controls.")
        let image = fixture.model.cursor.shape?.image
        fixture.viewers.all[0].onCursor?(.init(image: source, hotspot: .zero), ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(fixture.model.cursor.shape?.image === image, "The controller's cursor takes priority over the separate video connection.")
        try await fixture.channel.emitCursor(remote)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.model.cursor.shape?.image === image, "Identical images should not be decoded again.")
        XCTAssertTrue(fixture.model.controlsDesktop)
    }

    private func wait(timeout: TimeInterval = 4, until condition: () async -> Bool) async throws {
        // Match the model's active-time clock when the test Mac sleeps/wakes.
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("Timed out waiting for desktop recovery")
        throw DesktopProblem(code: "test_timeout", message: "Desktop recovery timed out")
    }
    private func fixture() throws -> (model: DesktopModel, channel: RecoveryChannel, viewers: RecoveryViewers) {
        let suite = "desktop-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let channel = RecoveryChannel()
        let api = DaemonHTTP(channel: channel, agentType: "")
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in DesktopNativeFixtureRemote(api: api) })
        let workspace = Workspace(id: "recovery-test", name: "Desktop", runtime: .cloud(workspaceId: "recovery-test"), createdAt: isoNow())
        let viewers = RecoveryViewers(image: testImage())
        let model = DesktopModel(workspace: workspace, stores: stores, provider: RecoveryProvider(), makeViewer: { viewers.make() })
        return (model, channel, viewers)
    }
    private func testImage() -> CGImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }.cgImage!
    }
    private func capture(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        #if targetEnvironment(simulator)
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        #endif
    }
}

@MainActor private final class RecoveryViewers {
    var all: [RecoveryViewer] = []
    var holdsFrames = false
    let image: CGImage
    init(image: CGImage) { self.image = image }
    func make() -> RecoveryViewer {
        let value = RecoveryViewer(image: image)
        value.holdsFrames = holdsFrames
        all.append(value)
        return value
    }
}

private final class RecoveryViewer: DesktopViewing {
    var onFrame: ((DesktopDisplayFrame) -> Void)?
    var onState: ((Bool, String?) -> Void)?
    var onCursor: ((DesktopCursorShape, TimeInterval) -> Void)?
    let image: CGImage
    var refreshes = 0
    var holdsFrames = false
    init(image: CGImage) { self.image = image }
    func connect(port: Int, settings: DesktopStreamSettings, debugLogging: Bool) {
        onState?(true, nil)
        if !holdsFrames { frame() }
    }
    func disconnect() {}
    func setFrameRate(_ value: Int) {}
    func requestFreshFrame() { refreshes += 1; if !holdsFrames { frame() } }
    func frame() {
        onFrame?(.init(image: image, sourceSize: CGSize(width: 4, height: 3), requestedAt: ProcessInfo.processInfo.systemUptime))
    }
}

@MainActor private final class RecoveryProvider: WorkspaceDesktopProvider {
    func status() async throws -> DesktopProviderStatus { .init(supported: true, enabled: true, available: true, credentials: false) }
    func authorize(api: DaemonHTTP, status: DesktopProviderStatus, resuming: Bool) async throws -> DesktopSnapshot {
        try await api.decode("GET", "/surfaces/desktop", quiet: true)
    }
    func openDisplay(api: DaemonHTTP, session: DesktopSession) async throws -> DesktopDisplayConnection {
        .init(port: 1234, cleanup: {})
    }
}

private actor RecoveryChannel: StreamingDaemonChannel {
    nonisolated let label = "recovery-fixture"
    private(set) var openCount = 0
    private(set) var inputs: [DesktopInput] = []
    private var controller: DesktopController?
    private var nextDelay: TimeInterval = 0
    private var rejectHeartbeat = false
    private var rejectAction = false
    private var cursor: DesktopRemoteCursor?
    private var cursorRevision: Int64 = 0
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private(set) var streamOpens = 0
    var watching: Bool { continuation != nil }
    func delayNextAction(_ delay: TimeInterval) { nextDelay = delay }
    func failNextHeartbeat() { rejectHeartbeat = true }
    func failNextActionAfterDispatch() { rejectAction = true }

    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.continuation = continuation
        streamOpens += 1
        return stream
    }
    func closeEvents() { continuation?.finish() }
    func emitCursor(_ value: DesktopRemoteCursor) throws {
        cursor = value; cursorRevision += 1
        continuation?.yield(try JSONEncoder().encode(currentSnapshot()))
    }
    private func currentSnapshot() -> DesktopSnapshot {
        DesktopSnapshot(id: "desktop", workspaceId: "fixture", version: 2, revision: Int64(openCount * 10 + (controller == nil ? 0 : 1)) + cursorRevision, instanceId: "fixture", state: "ready", supported: true, enabled: true, available: true, os: "linux", capabilities: .init(), geometry: .init(width: 4, height: 3, revision: 1), controller: controller, authorizationExpiresAt: nil, error: nil, cursor: cursor)
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        let body = jsonBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
        if path == "/surfaces/desktop" {
            return try reply(currentSnapshot())
        }
        if method == "POST", path == "/surfaces/desktop/sessions" {
            openCount += 1
            return try reply(DesktopSession(id: "s\(openCount)", surfaceId: "desktop", mode: "view", controller: nil))
        }
        if path.hasSuffix("/control") {
            let action = body["action"] as? String
            if action == "renew", rejectHeartbeat { rejectHeartbeat = false; throw URLError(.networkConnectionLost) }
            if action == "acquire" {
                controller = .init(sessionId: id, actor: "user", name: "You", runId: nil, chatId: nil, generation: Int64(openCount), expiresAt: "2099-01-01T00:00:00Z")
            }
            if action == "release", controller?.sessionId == id { controller = nil }
            return try reply(DesktopSession(id: id, surfaceId: "desktop", mode: controller?.sessionId == id ? "control" : "view", controller: controller))
        }
        if method == "DELETE" {
            let sessionId = path.split(separator: "/").last.map(String.init)
            if sessionId == controller?.sessionId { controller = nil }
            return (200, "{}")
        }
        if path == "/surfaces/desktop/actions" {
            let input = try JSONDecoder().decode(DesktopInput.self, from: JSONSerialization.data(withJSONObject: body["action"]!))
            inputs.append(input)
            let delay = nextDelay; nextDelay = 0
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            if rejectAction { rejectAction = false; throw URLError(.networkConnectionLost) }
            return try reply(DesktopReceipt(id: body["requestId"] as? String ?? "a", sessionId: body["sessionId"] as? String ?? "s", surfaceId: "desktop", kind: input.kind, status: "dispatched", error: nil, text: nil))
        }
        return (404, "{}")
    }
    private func reply<T: Encodable>(_ value: T) throws -> (status: Int, body: String) {
        (200, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
}
