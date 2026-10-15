import XCTest
import UIKit
@testable import Mindwire

@MainActor
final class DesktopInteractionTests: XCTestCase {
    func testBackgroundResumesOnlyRequestedConnections() {
        var lifecycle = DesktopConnectionLifecycle()
        XCTAssertFalse(lifecycle.resume())
        XCTAssertFalse(lifecycle.background())
        lifecycle.connect()
        XCTAssertTrue(lifecycle.background())
        XCTAssertFalse(lifecycle.background())
        XCTAssertTrue(lifecycle.resume())
        XCTAssertFalse(lifecycle.resume(), "Repeated active events must not open duplicate connections.")
        XCTAssertTrue(lifecycle.background())
        lifecycle.disconnect()
        XCTAssertFalse(lifecycle.resume(), "Done and Disconnect cancel automatic resume.")
    }

    func testPointerBacklogCoalescesWithoutCrossingClicksOrButtonChanges() {
        var queue = DesktopInputBuffer()
        for x in 0..<1000 { XCTAssertTrue(queue.append(.init(kind: "pointer", x: x, y: 2, buttons: 0))) }
        XCTAssertTrue(queue.append(.init(kind: "click", x: 999, y: 2)))
        XCTAssertTrue(queue.append(.init(kind: "pointer", x: 800, y: 2, buttons: 1)))
        XCTAssertTrue(queue.append(.init(kind: "pointer", x: 700, y: 2, buttons: 0)))
        XCTAssertEqual(queue.pending.map(\.kind), ["pointer", "click", "pointer", "pointer"])
        XCTAssertEqual(queue.next()?.x, 999)
        XCTAssertEqual(queue.next()?.kind, "click")
        XCTAssertEqual(queue.next()?.buttons, 1)
        XCTAssertEqual(queue.next()?.buttons, 0)
        XCTAssertNil(queue.next())
    }

    func testTypingCoalescesUntilAKeyAndKeepsUnicodeSeparate() {
        var queue = DesktopInputBuffer()
        for input in DesktopTyping.inputs("aB!", keyboardText: true) { XCTAssertTrue(queue.append(input)) }
        XCTAssertTrue(queue.append(.init(kind: "key", keys: ["Backspace"])))
        for input in DesktopTyping.inputs("你好\n", keyboardText: true) { XCTAssertTrue(queue.append(input)) }
        XCTAssertEqual(queue.next(), .init(kind: "text", text: "aB!", textMode: "keyboard"))
        XCTAssertEqual(queue.next()?.keys, ["Backspace"])
        XCTAssertEqual(queue.next(), .init(kind: "text", text: "你好"))
        XCTAssertEqual(queue.next()?.keys, ["Enter"])
    }

    func testTypingFallsBackToPhysicalKeysOnOlderServices() {
        XCTAssertEqual(DesktopTyping.inputs("aA!\t\n", keyboardText: false).map(\.keys),
                       [["a"], ["Shift", "a"], ["Shift", "1"], ["Tab"], ["Enter"]])
        XCTAssertEqual(DesktopTyping.inputs("C", modifiers: ["Meta"], keyboardText: true).first?.keys,
                       ["Meta", "Shift", "c"])
        XCTAssertEqual(DesktopTyping.inputs("🙂", keyboardText: false).first?.text, "🙂")
    }

    func testNativeKeyboardSendsImmediatelyAndDoesNotKeepTypedText() {
        let input = DesktopKeyboardView()
        var events: [DesktopKeyboardEvent] = []
        input.send = { events.append($0) }
        input.insertText("a")
        input.insertText("🙂")
        input.insertText("\n")
        input.deleteBackward()
        input.deleteBackward()
        XCTAssertEqual(events, [.text("a"), .text("🙂"), .text("\n"), .key(["Backspace"]), .key(["Backspace"])])
        XCTAssertFalse(input.text.contains("a"))
        XCTAssertEqual(input.text.count, 1, "Keep only the invisible keyboard sentinel.")
    }

    func testIMEPreeditIsNotSentUntilCommitted() {
        let input = DesktopKeyboardView()
        var events: [DesktopKeyboardEvent] = []
        input.send = { events.append($0) }
        input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(events.isEmpty)
        input.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(events.isEmpty)
        input.unmarkText()
        XCTAssertEqual(events, [.text("你")])
        input.insertText("好")
        XCTAssertEqual(events, [.text("你"), .text("好")])
    }

    func testHiddenKeyboardClientCanFocusAndDismiss() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let input = DesktopKeyboardView()
        input.frame = CGRect(x: 0, y: 0, width: 1, height: 1); input.alpha = 0.01
        input.wantsKeyboard = true
        controller.view.addSubview(input)
        input.requestKeyboard()
        XCTAssertTrue(input.isFirstResponder)
        input.wantsKeyboard = false
        input.resignFirstResponder()
        XCTAssertFalse(input.isFirstResponder)
        XCTAssertEqual(input.text.count, 1)
    }

    func testMouseStickClampsAtActualPixelEdges() {
        var pointer = DesktopPointerPosition()
        let size = CGSize(width: 1280, height: 800)
        pointer.move(CGSize(width: 5000, height: -5000), pixels: size)
        XCTAssertEqual(pointer.pixel(in: size), CGPoint(x: 1279, y: 0))
        pointer.move(CGSize(width: -5000, height: 5000), pixels: size)
        XCTAssertEqual(pointer.pixel(in: size), CGPoint(x: 0, y: 799))
    }

    func testMouseStickStopsWhenFingerStopsAndReversesImmediately() {
        let hd = CGSize(width: 1920, height: 1080)
        var motion = DesktopPointerMotion()
        XCTAssertEqual(motion.update(translation: .zero, pixels: hd), .zero)
        let moved = CGSize(width: 10, height: -5)
        XCTAssertEqual(motion.update(translation: moved, pixels: hd), CGSize(width: 60, height: -30))
        for _ in 0..<120 {
            XCTAssertEqual(motion.update(translation: moved, pixels: hd), .zero,
                           "A held finger must not keep moving the cursor")
        }
        XCTAssertEqual(motion.update(translation: CGSize(width: 8, height: -5), pixels: hd),
                       CGSize(width: -12, height: 0), "Reversing a little must reverse the pointer immediately")
    }

    func testMouseStickTravelIsLinearAcrossTouchFrequencyAndResolution() {
        let hd = CGSize(width: 1920, height: 1080)
        let retina = CGSize(width: 3840, height: 2160)
        var single = DesktopPointerMotion(), sampled = DesktopPointerMotion(), highResolution = DesktopPointerMotion()
        let travel = CGSize(width: 40, height: 20)
        let direct = single.update(translation: travel, pixels: hd)
        var total = CGSize.zero
        for step in 1...20 {
            let delta = sampled.update(translation: CGSize(width: step * 2, height: step), pixels: hd)
            total.width += delta.width; total.height += delta.height
        }
        XCTAssertEqual(total, direct, "The same finger travel must not accelerate with more touch updates")
        let high = highResolution.update(translation: travel, pixels: retina)
        XCTAssertEqual(direct.width / hd.width, high.width / retina.width, accuracy: 0.000001)
        XCTAssertEqual(direct.height / hd.height, high.height / retina.height, accuracy: 0.000001)
    }

    func testMouseStickSensitivityOnlyScalesDistance() {
        let pixels = CGSize(width: 1920, height: 1080)
        let travel = CGSize(width: 12, height: -8)
        var slow = DesktopPointerMotion(), normal = DesktopPointerMotion(), fast = DesktopPointerMotion()
        let normalDelta = normal.update(translation: travel, pixels: pixels)
        let slowDelta = slow.update(translation: travel, pixels: pixels, sensitivity: 0.5)
        let fastDelta = fast.update(translation: travel, pixels: pixels, sensitivity: 2)
        XCTAssertEqual(slowDelta, CGSize(width: normalDelta.width / 2, height: normalDelta.height / 2))
        XCTAssertEqual(fastDelta, CGSize(width: normalDelta.width * 2, height: normalDelta.height * 2))
        XCTAssertEqual(fast.update(translation: travel, pixels: pixels, sensitivity: 2), .zero)
    }

    func testMouseStickUsesFullFingerTravelAndNewDragDoesNotJump() {
        let pixels = CGSize(width: 1920, height: 1080)
        var motion = DesktopPointerMotion()
        let outside = DesktopPointerMotion.radius * 3
        XCTAssertEqual(motion.update(translation: CGSize(width: outside, height: 0), pixels: pixels).width, outside * 6)
        XCTAssertEqual(motion.update(translation: CGSize(width: outside - 2, height: 0), pixels: pixels).width, -12,
                       "The thumb's visual boundary must not swallow reverse movement")
        motion.reset() // Lift, cancellation, background or dismissal.
        XCTAssertEqual(motion.update(translation: .zero, pixels: pixels), .zero)
        XCTAssertEqual(motion.update(translation: CGSize(width: 1, height: 0), pixels: pixels).width, 6)
    }

    func testLocalCursorMovesWithoutAnotherFrameAndDirectTouchHidesIt() {
        let cursor = DesktopCursor()
        let canvas = DesktopCanvasView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let pixels = CGSize(width: 1920, height: 1080)
        canvas.cursor = cursor
        cursor.move(CGSize(width: 100, height: -50), pixels: pixels)
        XCTAssertEqual(canvas.pointer, cursor.normalized, "The local overlay updates synchronously without any video or network callback")
        XCTAssertEqual(cursor.pixel(in: pixels), CGPoint(x: 1060, y: 490))
        canvas.cursor = nil
        XCTAssertNil(canvas.pointer, "Direct touch shows no local cursor")
        cursor.place(at: CGPoint(x: 10, y: 20), pixels: pixels)
        XCTAssertNil(canvas.pointer)
        canvas.cursor = cursor
        XCTAssertEqual(canvas.pointer, cursor.normalized, "Changing modes preserves the current position")
    }

    func testTopAlignmentDoesNotCenterShortScreens() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 40)).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
        }
        let canvas = DesktopCanvasView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        canvas.show(try XCTUnwrap(image.cgImage))
        canvas.layoutIfNeeded()
        XCTAssertEqual(canvas.displayedFrame.minY, 0, accuracy: 0.1)
        canvas.alignTop = false
        XCTAssertEqual(canvas.displayedFrame.midY, 100, accuracy: 0.1)
        canvas.alignTop = true
        XCTAssertEqual(canvas.displayedFrame.minY, 0, accuracy: 0.1)
    }

    func testDesktopRuntimeSelectionUsesProviderDeclaration() throws {
        let catalog = try JSONDecoder().decode(DesktopRuntimeCatalog.self, from: Data(#"{"default_target":"linux","targets":[{"id":"linux","runtime":{"os":"linux"}},{"id":"macos","runtime":{"os":"darwin"}}]}"#.utf8))
        let claims = Data(#"{"desktop_runtime":"macos"}"#.utf8).base64EncodedString()
        XCTAssertEqual(catalog.desktopTarget(token: "header.\(claims).signature")?.id, "macos")
        XCTAssertEqual(catalog.desktopTarget(token: "opaque")?.id, "linux")
        let bad = Data(#"{"desktop_runtime":"../other"}"#.utf8).base64EncodedString()
        XCTAssertNil(catalog.desktopTarget(token: "header.\(bad).signature"))
    }

    func testProtocolOneCapabilitiesRemainBackwardCompatible() throws {
        let old = Data(#"{"view":true,"capture":true,"pointer":true,"keyboard":true,"text":true,"clipboardRead":true,"clipboardWrite":true}"#.utf8)
        let capabilities = try JSONDecoder().decode(DesktopCapabilities.self, from: old)
        XCTAssertNil(capabilities.keyboardText)
        XCTAssertNil(capabilities.extendedKeys)
        XCTAssertTrue(capabilities.keyboard)
    }

    func testBatchQueueRejectsOverflowWithoutDroppingPartOfAPaste() {
        var queue = DesktopInputBuffer()
        XCTAssertTrue(queue.append(.init(kind: "key", keys: ["Enter"])))
        let paste = (0..<256).map { _ in DesktopInput(kind: "key", keys: ["a"]) }
        XCTAssertFalse(queue.append(contentsOf: paste))
        XCTAssertEqual(queue.pending, [.init(kind: "key", keys: ["Enter"])])
        let text = String(repeating: "a", count: 5000)
        XCTAssertEqual(DesktopTyping.inputs(text, keyboardText: true).map { $0.text?.count }, [4096, 904])
    }

    func testNativeSessionPreparationUsesPrivateStdinAndNoTaskDelete() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopNativeInputProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        DesktopNativeInputProtocol.reset(exitCode: 0)
        let input = Data(#"{"username":"fixture","password":"sensitive-test-value"}"#.utf8)
        let native = CloudDesktopNativeInput(baseURL: URL(string: "https://desktop.test")!, token: "fixture", session: session)
        let result = try await native.run(target: "macos", command: ["/usr/bin/perl", "-e", "fixture script"], input: input)
        XCTAssertEqual(String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), #"{"ready":true}"#)
        let requests = DesktopNativeInputProtocol.requests
        XCTAssertEqual(requests.map(\.path), ["/runtimes/macos/exec/stream", "/runtimes/macos/exec/task-1/input"])
        let launch = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
        XCTAssertEqual(launch["keep_logs"] as? Bool, false)
        XCTAssertFalse(String(decoding: requests[0].body, as: UTF8.self).contains("sensitive-test-value"))
        XCTAssertEqual(Data(base64Encoded: requests[1].body), input)
    }

    func testNativeSessionFailureDoesNotExposeRawOutput() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DesktopNativeInputProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        DesktopNativeInputProtocol.reset(exitCode: 1)
        let native = CloudDesktopNativeInput(baseURL: URL(string: "https://desktop.test")!, token: "fixture", session: session)
        do {
            _ = try await native.run(target: "macos", command: ["/usr/bin/perl"], input: Data("private".utf8))
            XCTFail("Expected a failed preparation")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("private"))
            XCTAssertEqual((error as? DesktopProblem)?.code, "login_unavailable")
        }
    }
}

private final class DesktopNativeInputProtocol: URLProtocol {
    struct Record { let path: String; let body: Data }
    private static let lock = NSLock()
    private static var records: [Record] = []
    private static var exitCode = 0
    static var requests: [Record] { lock.withLock { records } }
    static func reset(exitCode: Int) { lock.withLock { records = []; self.exitCode = exitCode } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "desktop.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let exit = Self.lock.withLock { Self.records.append(Record(path: path, body: body)); return Self.exitCode }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": path.hasSuffix("/stream") ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path.hasSuffix("/stream") {
            let marker = Data("MINDWIRE_NATIVE_INPUT_READY\n".utf8).base64EncodedString()
            let output = Data(#"{"ready":true}"#.utf8).base64EncodedString()
            let error = Data("private provider failure".utf8).base64EncodedString()
            let wire = "event: task_id\ndata: {\"task_id\":\"task-1\"}\n\n"
                + "event: stdout\ndata: {\"data\":\"\(marker)\"}\n\n"
                + "event: stderr\ndata: {\"data\":\"\(error)\"}\n\n"
                + "event: stdout\ndata: {\"data\":\"\(output)\"}\n\n"
                + "event: exit\ndata: {\"exit_code\":\(exit)}\n\n"
            client?.urlProtocol(self, didLoad: Data(wire.utf8))
        } else { client?.urlProtocol(self, didLoad: Data("{}".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
