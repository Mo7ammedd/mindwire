import XCTest
import Network
import UIKit
@testable import Mindwire

@MainActor
final class DesktopStreamTests: XCTestCase {
    func testDefaultStreamIsLighterAndOriginalKeepsNativePixels() {
        let settings = DesktopStreamSettings()
        XCTAssertEqual(settings.frameRate, 30)
        XCTAssertEqual(settings.quality, .balanced)
        let retina = CGSize(width: 3024, height: 1964)
        XCTAssertEqual(settings.quality.imageSize(for: retina), CGSize(width: 1920, height: 1246))
        XCTAssertEqual(DesktopStreamQuality.dataSaver.imageSize(for: retina).width, 1280)
        XCTAssertEqual(DesktopStreamQuality.original.imageSize(for: retina), retina)
        let small = CGSize(width: 800, height: 600)
        XCTAssertEqual(settings.quality.imageSize(for: small), small, "Never upscale a small desktop")
        XCTAssertEqual(DesktopStreamSettings(framesPerSecond: 0).frameRate, 30)
    }

    func testFragmentedRFBNegotiationDisablesContinuousUpdatesAndAddsQualityHint() throws {
        var parser = DesktopRFBRequests(quality: .balanced)
        let input = handshake + encodings([16, -313, -32, -512, 0]) + request
        var messages: [DesktopRFBRequests.Message] = []
        for byte in input { messages += try parser.append(Data([byte])) }
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0].data, Data("RFB 003.008\n".utf8))
        XCTAssertEqual(messages[1].data, Data([1]))
        XCTAssertEqual(messages[2].data, Data([1]))
        XCTAssertEqual(messages[3].data, encodings([16, 0, -24]))
        XCTAssertEqual(messages[4].data, request)
        XCTAssertTrue(messages[4].isFrameRequest)
    }

    func testOriginalQualityDoesNotRequestJPEGOrChangeNativePixelFormat() throws {
        var parser = DesktopRFBRequests(quality: .original)
        _ = try parser.append(handshake)
        let format = Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        let messages = try parser.append(format + encodings([7, 16, -313, -23]))
        XCTAssertEqual(messages.map(\.data), [format, encodings([7, 16])])
    }

    func testLegacyRFBHandshakeAndUnsupportedMessagesHaveBoundedParsing() throws {
        var legacy = DesktopRFBRequests(quality: .original)
        let messages = try legacy.append(Data("RFB 003.003\n".utf8) + Data([1]) + request)
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages.last!.isFrameRequest)
        var oversized = DesktopRFBRequests(quality: .original)
        _ = try oversized.append(handshake)
        XCTAssertThrowsError(try oversized.append(Data([2, 0, 255, 255])))
        var input = DesktopRFBRequests(quality: .original)
        _ = try input.append(handshake)
        XCTAssertThrowsError(try input.append(Data([5, 1, 0, 10, 0, 10])), "Input must use the shared controller")
        var auth = DesktopRFBRequests(quality: .original)
        _ = try auth.append(Data("RFB 003.008\n".utf8))
        XCTAssertThrowsError(try auth.append(Data([2])), "The adapter must never collect a VNC password")
    }

    func testFrameRatePacesActualUpstreamRequestsAndCanChangeWithoutReconnecting() async throws {
        let probe = try DesktopStreamProbe()
        defer { probe.close() }
        let port = try await probe.start()
        let (bridge, localPort) = try await DesktopStreamBridge.open(port: port, settings: .init(framesPerSecond: 15))
        defer { bridge.close() }
        let client = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(localPort))!, using: .tcp)
        defer { client.cancel() }
        let queue = DispatchQueue(label: "desktop-stream-client-test")
        let ready = expectation(description: "local viewer connected")
        client.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        client.start(queue: queue)
        await fulfillment(of: [ready], timeout: 4)
        let payload = handshake + (0..<10).reduce(into: Data()) { data, _ in data.append(request) }
        client.send(content: payload, completion: .contentProcessed { _ in })
        try await wait { probe.times.count >= 3 }
        let initial = probe.times
        XCTAssertGreaterThan(initial[2] - initial[0], 0.10, "15 FPS must pace the server, not just the UI")
        let changedAt = CACurrentMediaTime()
        bridge.setFrameRate(60)
        try await wait { probe.times.count == 10 }
        XCTAssertLessThan(probe.times.last! - changedAt, 0.38, "Changing FPS should release the pending request at the new rate")
        XCTAssertEqual(probe.connectionCount, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.times.count, 10, "The adapter must not manufacture requests while idle")
    }

    private var handshake: Data { Data("RFB 003.008\n".utf8) + Data([1, 1]) }
    private var request: Data { Data([3, 1, 0, 0, 0, 0, 0, 2, 0, 2]) }
    private func encodings(_ values: [Int32]) -> Data {
        var data = Data([2, 0, UInt8(values.count >> 8), UInt8(truncatingIfNeeded: values.count)])
        for value in values {
            var wire = value.bigEndian
            withUnsafeBytes(of: &wire) { data.append(contentsOf: $0) }
        }
        return data
    }
    private func wait(until condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(4)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out waiting for upstream frame requests")
        if !condition() { throw DesktopProblem(code: "test_timeout", message: "No frame requests") }
    }
}

/// Records fixed-size update requests received by a real loopback TCP peer.
/// It does not reuse the production parser, timers or stream implementation.
private final class DesktopStreamProbe {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "desktop-stream-probe")
    private let lock = NSLock()
    private var received: [TimeInterval] = []
    private var clients: [NWConnection] = []
    private var connections = 0
    var times: [TimeInterval] { lock.withLock { received } }
    var connectionCount: Int { lock.withLock { connections } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    if let port = self?.listener.port { resumed = true; continuation.resume(returning: Int(port.rawValue)) }
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] client in
                guard let self else { client.cancel(); return }
                self.lock.withLock { self.clients.append(client); self.connections += 1 }
                client.start(queue: self.queue)
                self.read(client, buffer: Data(), handshake: true)
            }
            listener.start(queue: queue)
        }
    }
    private func read(_ client: NWConnection, buffer: Data, handshake: Bool) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self, let data, error == nil, !done else { return }
            var buffer = buffer + data
            var handshake = handshake
            if handshake, buffer.count >= 14 { buffer.removeFirst(14); handshake = false }
            if !handshake {
                while buffer.count >= 10 {
                    buffer.removeFirst(10)
                    self.lock.withLock { self.received.append(CACurrentMediaTime()) }
                }
            }
            self.read(client, buffer: buffer, handshake: handshake)
        }
    }
    func close() { listener.cancel(); lock.withLock { clients.forEach { $0.cancel() } } }
}
