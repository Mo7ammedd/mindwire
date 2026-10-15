import XCTest
import SwiftUI
@testable import Mindwire

/// The Go TestLinuxDesktopInput fixture owns a disposable TigerVNC/Tk display.
/// Native video and the shared HTTP controller use separate connections, just
/// as in the cloud path. No account, real workspace or host screen is involved.
@MainActor
final class LinuxDesktopNativeTests: XCTestCase {
    private struct Fixture: Decodable { let apiURL: URL; let token: String; let vncPort: Int }
    private struct State: Decodable {
        let fixture: String
        let pointer: [Int]
        let presses: [Int]
        let releases: [Int]
        let pressPositions: [[Int]]
        let releasePositions: [[Int]]
        let text: String
    }

    func testNativeLinuxCursorTouchTypingAndResume() async throws {
        guard let file = ProcessInfo.processInfo.environment["MINDWIRE_LINUX_NATIVE_FIXTURE"] else {
            throw XCTSkip("Requires the isolated Linux desktop fixture.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        guard fixture.apiURL.host == "127.0.0.1" else { throw DesktopProblem(code: "fixture", message: "Loopback fixture required.") }
        defer { try? Data().write(to: URL(fileURLWithPath: file + ".done")) }
        let transport = URLSessionDaemonChannel { method, path, body, _ in
            var request = URLRequest(url: URL(string: path, relativeTo: fixture.apiURL)!.absoluteURL)
            request.httpMethod = method; request.httpBody = body
            request.setValue("Bearer " + fixture.token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return request
        }
        let channel = DelayedLinuxInputChannel(base: transport)
        let api = DaemonHTTP(channel: channel, agentType: "")
        func state() async throws -> State {
            let value: State = try await api.decode("GET", "/fixture/state", quiet: true)
            guard value.fixture == "mindwire-linux-desktop-v1" else {
                throw DesktopProblem(code: "fixture", message: "Disposable Linux input window required.")
            }
            return value
        }
        let before = try await state()
        let suite = "linux-desktop-native-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in DesktopNativeFixtureRemote(api: api) })
        let workspace = Workspace(id: "linux-desktop-fixture", name: "Linux desktop", runtime: .cloud(workspaceId: "linux-desktop-fixture"), createdAt: isoNow())
        let model = DesktopModel(workspace: workspace, stores: stores, provider: LinuxNativeFixtureProvider(api: api, port: fixture.vncPort))
        defer { model.disconnect() }
        await model.load()
        await model.connect(automaticallySignIn: false)
        try await wait("native Linux video") { model.connected && model.image != nil }
        let image = try XCTUnwrap(model.image)
        XCTAssertEqual(image.width, 1600)
        XCTAssertEqual(image.height, 1000)
        try await wait("automatic mouse control") { model.controlsDesktop }
        XCTAssertTrue(model.controlsDesktop, model.error ?? "No controller")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let cursor = model.cursor
        let screen = UIHostingController(rootView: LinuxNativePreview(model: model, cursor: cursor, cursorMode: true))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await wait("native canvas layout") { self.canvas(in: screen.view)?.displayedFrame.width ?? 0 > 0 }
        let canvas = try XCTUnwrap(canvas(in: screen.view))
        let pixels = CGSize(width: image.width, height: image.height)
        cursor.place(at: CGPoint(x: 500, y: 350), pixels: pixels)
        var motion = DesktopPointerMotion()
        cursor.move(motion.update(translation: CGSize(width: 12, height: 0), pixels: pixels), pixels: pixels)
        let point = cursor.pixel(in: pixels)
        XCTAssertEqual(canvas.pointer, cursor.normalized, "Cursor must move before any network or video response")
        model.send(.init(kind: "pointer", x: Int(point.x), y: Int(point.y), buttons: 0))
        try await wait("Linux pointer") { try await state().pointer == [Int(point.x), Int(point.y)] }
        model.send(.init(kind: "click", x: Int(point.x), y: Int(point.y)))
        try await wait("Linux cursor click") { try await state().presses.count == before.presses.count + 1 }

        let keyboard = DesktopKeyboardView()
        keyboard.send = { event in
            switch event {
            case .text(let text): model.type(text)
            case .key(let keys): model.send(.init(kind: "key", keys: keys))
            }
        }
        keyboard.insertText("\nNative iPhone Linux test")
        let expectedText = before.text + "\nNative iPhone Linux test"
        try await wait("exact native keyboard text") { try await state().text == expectedText }
        try await wait("remote cursor shape") { model.cursor.shape != nil }
        XCTAssertNotNil(model.cursor.shape, "The phone must receive Linux's actual cursor shape.")
        for (x, name) in [(240, "clickable hand"), (640, "busy"), (1040, "resize")] {
            let previousShape = try XCTUnwrap(model.cursor.shape?.image)
            cursor.place(at: CGPoint(x: x, y: 890), pixels: pixels)
            model.send(.init(kind: "pointer", x: x, y: 890, buttons: 0))
            try await wait("Linux \(name) position") { try await state().pointer == [x, 890] }
            try await wait("actual Linux \(name) cursor") { model.cursor.shape?.image !== previousShape }
        }
        try await wait("input and rendered frame synchronization") { !model.inputSynchronizing }
        try saveScreenshot(window, to: file + ".cursor.png")

        screen.rootView = LinuxNativePreview(model: model, cursor: cursor, cursorMode: false)
        try await wait("direct touch mode") { canvas.cursor == nil }
        XCTAssertNil(canvas.pointer)
        // Exercise the canvas's actual UIKit tap handler and coordinate mapping.
        let tap = LinuxFixtureTap(point: CGPoint(x: canvas.displayedFrame.width * 0.4,
                                                y: canvas.displayedFrame.height * 0.3))
        _ = canvas.perform(NSSelectorFromString("click:"), with: tap)
        try await wait("direct Linux touch") { try await state().presses.count == before.presses.count + 2 }
        let touched = try await state()
        XCTAssertEqual(touched.pointer, [640, 300])
        try saveScreenshot(window, to: file + ".touch.png")
        XCTAssertNil(model.error)

        // Drive the touchpad state machine into the real controller. A resting
        // finger and a slow glide must not press the button or select text.
        cursor.place(at: CGPoint(x: 640, y: 300), pixels: pixels)
        var gesture = DesktopTouchpadGesture()
        func touch(_ x: CGFloat = 40, _ y: CGFloat = 40, taps: Int = 1) -> DesktopTouchpadGesture.Touch {
            .init(id: 1, point: CGPoint(x: x, y: y), tapCount: taps)
        }
        func deliver(_ events: [DesktopPointerEvent]) {
            for event in events { cursor.handle(event, pixels: pixels, send: model.send) }
        }
        try await wait("ready for touchpad glide") { model.acceptsInput && !model.inputBusy && !model.inputSynchronizing }
        deliver(gesture.began([touch()], at: 0))
        try await Task.sleep(for: .milliseconds(450))
        deliver(gesture.moved([touch(42, 40)]))
        try await wait("slow Linux touchpad glide") { try await state().pointer == [642, 300] }
        deliver(gesture.moved([touch(60, 52)]))
        deliver(gesture.ended([touch(60, 52)], at: 1))
        try await wait("Linux hover without selection") { try await state().pointer == [660, 312] }
        let hovered = try await state()
        XCTAssertEqual(hovered.presses.count, touched.presses.count)
        XCTAssertEqual(hovered.releases.count, touched.releases.count)

        // A completed tap and a second tap-and-hold deliberately start dragging.
        try await wait("ready for touchpad drag") { model.acceptsInput && !model.inputBusy && !model.inputSynchronizing }
        deliver(gesture.began([touch()], at: 2))
        deliver(gesture.ended([touch()], at: 2.1))
        deliver(gesture.began([touch(taps: 2)], at: 2.2))
        try await wait("Linux double-tap hold") { try await state().presses.count == hovered.presses.count + 2 }
        deliver(gesture.moved([touch(80, 60, taps: 2)]))
        deliver(gesture.ended([touch(80, 60, taps: 2)], at: 3))
        try await wait("Linux drag release") { try await state().releases.count == hovered.releases.count + 2 }
        let afterDrag = try await state()
        XCTAssertEqual(afterDrag.pointer, [700, 332])

        // Delay an actual controller acknowledgement while the user keeps
        // moving, releases a drag, clicks, then moves again. Linux must observe
        // the click where it was captured, never at the newer cursor position.
        screen.rootView = LinuxNativePreview(model: model, cursor: cursor, cursorMode: true)
        try await wait("cursor before delayed input") { canvas.cursor != nil && model.acceptsInput && !model.inputBusy }
        cursor.place(at: CGPoint(x: 800, y: 400), pixels: pixels)
        await channel.delayNextAction(1.25)
        model.handlePointer(.button(true))
        try await wait("delayed Linux input acknowledgement") { await channel.delaying }
        model.handlePointer(.move(CGSize(width: 80, height: 40)))
        try await wait("input delay indicator") { model.inputSynchronizing }
        XCTAssertTrue(model.acceptsInput)
        XCTAssertTrue(model.canMovePointer)
        model.handlePointer(.move(CGSize(width: 40, height: 10)))
        model.handlePointer(.button(false))
        model.handlePointer(.click("left", 1))
        model.handlePointer(.move(CGSize(width: -200, height: 50)))
        XCTAssertEqual(cursor.pixel(in: pixels), CGPoint(x: 720, y: 500))
        XCTAssertEqual(canvas.pointer, cursor.normalized, "The local pointer must not wait for the remote queue")
        try await wait("ordered Linux input drained") { !model.inputBusy && !model.inputSynchronizing }
        let queued = try await state()
        XCTAssertEqual(queued.pointer, [720, 500])
        XCTAssertEqual(Array(queued.pressPositions.suffix(2)), [[1, 800, 400], [1, 920, 450]])
        XCTAssertEqual(Array(queued.releasePositions.suffix(2)), [[1, 920, 450], [1, 920, 450]])
        XCTAssertEqual(queued.presses.count, afterDrag.presses.count + 2)
        XCTAssertNil(model.error)
        try saveScreenshot(window, to: file + ".queued.png")

        model.suspend()
        await model.resume()
        try await wait("native Linux reconnect") { model.connected && model.image != nil }
        try await wait("restore requested mouse control") { model.controlsDesktop }
        let resumed = try await state()
        XCTAssertEqual(resumed.text, expectedText)
        XCTAssertEqual(resumed.presses.count, queued.presses.count)
        XCTAssertEqual(resumed.releases.count, queued.releases.count)
        XCTAssertNil(model.error)
    }

    private func wait(_ label: String, until condition: () async throws -> Bool) async throws {
        print("LINUX_NATIVE waiting: \(label)")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if try await condition() { print("LINUX_NATIVE verified: \(label)"); return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw DesktopProblem(code: "test_timeout", message: "Timed out: " + label)
    }
    private func canvas(in view: UIView) -> DesktopCanvasView? {
        if let canvas = view as? DesktopCanvasView { return canvas }
        return view.subviews.lazy.compactMap { self.canvas(in: $0) }.first
    }
    private func saveScreenshot(_ window: UIWindow, to path: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try image.pngData()?.write(to: URL(fileURLWithPath: path))
    }
}

private actor DelayedLinuxInputChannel: StreamingDaemonChannel {
    nonisolated let label = "delayed-linux-input-fixture"
    let base: URLSessionDaemonChannel
    private var nextDelay: Double = 0
    private(set) var delaying = false
    init(base: URLSessionDaemonChannel) { self.base = base }
    func delayNextAction(_ seconds: Double) { nextDelay = seconds }
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        let delay = method == "POST" && path == "/surfaces/desktop/actions" ? nextDelay : 0
        if delay > 0 { nextDelay = 0 }
        let result = try await base.perform(method: method, path: path, jsonBody: jsonBody)
        if delay > 0 {
            delaying = true
            defer { delaying = false }
            try await Task.sleep(for: .seconds(delay))
        }
        return result
    }
    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        try await base.stream(method: method, path: path, jsonBody: jsonBody)
    }
}

@MainActor
private final class LinuxNativeFixtureProvider: WorkspaceDesktopProvider {
    let api: DaemonHTTP
    let port: Int
    init(api: DaemonHTTP, port: Int) { self.api = api; self.port = port }
    func status() async throws -> DesktopProviderStatus { .init(supported: true, enabled: true, available: true, credentials: false) }
    func authorize(api: DaemonHTTP, status: DesktopProviderStatus, resuming: Bool) async throws -> DesktopSnapshot {
        try await api.decode("GET", "/surfaces/desktop", quiet: true)
    }
    func openDisplay(api: DaemonHTTP, session: DesktopSession) async throws -> DesktopDisplayConnection {
        DesktopDisplayConnection(port: port, cleanup: {})
    }
}

private final class LinuxFixtureTap: UITapGestureRecognizer {
    let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override func location(in view: UIView?) -> CGPoint { point }
}

private struct LinuxNativePreview: View {
    let model: DesktopModel
    let cursor: DesktopCursor
    let cursorMode: Bool
    var body: some View {
        VStack {
            Text(cursorMode ? "Cursor" : "Direct touch").font(.headline).padding()
            if let image = model.image {
                let pixels = CGSize(width: image.width, height: image.height)
                DesktopCanvas(image: image, canControl: model.acceptsInput, cursor: cursorMode ? cursor : nil, send: model.send)
                    .overlay(alignment: .bottom) {
                        if cursorMode {
                            DesktopPointerPad(mode: .stick, pixels: pixels, enabled: model.canMovePointer,
                                              event: model.handlePointer).frame(height: 96).padding(.bottom)
                        }
                    }
            }
        }.background(.black).preferredColorScheme(.dark)
    }
}
