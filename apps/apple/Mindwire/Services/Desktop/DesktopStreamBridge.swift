import Foundation
import Network

/// A loopback adapter for the existing SSH forward. It paces RFB update requests,
/// not video bytes, so a low FPS limit reduces upstream work without accumulating
/// old frames. Compressed server traffic passes through unchanged with backpressure.
/// Mouse and keyboard input continue to use the shared desktop controller.
// Connection state is confined to queue; the public callback has its own lock.
final class DesktopStreamBridge: @unchecked Sendable {
    /// RoyalVNCKit requests its next frame only after decoding the previous
    /// update. This watermark includes unchanged/cursor-only updates too.
    var onFrameCompleted: ((TimeInterval) -> Void)? {
        get { callbackLock.withLock { frameCompletion } }
        set { callbackLock.withLock { frameCompletion = newValue } }
    }
    private let callbackLock = NSLock()
    private var frameCompletion: ((TimeInterval) -> Void)?
    private let queue = DispatchQueue(label: "mindwire.desktop.stream", qos: .userInteractive)
    private let upstreamPort: UInt16
    private var parser: DesktopRFBRequests
    private var framesPerSecond: Int
    private var listener: NWListener?
    private var local: NWConnection?
    private var remote: NWConnection?
    private var ready: ((Result<Int, Error>) -> Void)?
    private var closed = false
    private var pending: [DesktopRFBRequests.Message] = []
    private var sending = false
    private var receivingClient = false
    private var delay: DispatchWorkItem?
    private var lastRequest: DispatchTime?
    private var lastFrameRequest: Data?
    private var frameRequestedAt: TimeInterval?
    private var refreshNextFrame = false

    private init(port: UInt16, settings: DesktopStreamSettings) {
        upstreamPort = port
        parser = DesktopRFBRequests(quality: settings.quality)
        framesPerSecond = settings.frameRate
    }

    static func open(port: Int, settings: DesktopStreamSettings) async throws -> (DesktopStreamBridge, Int) {
        guard let port = UInt16(exactly: port), port > 0 else {
            throw DesktopProblem(code: "invalid_display", message: "The desktop connection could not be opened.")
        }
        let bridge = DesktopStreamBridge(port: port, settings: settings)
        let localPort = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
                bridge.queue.async {
                    guard !bridge.closed else { continuation.resume(throwing: CancellationError()); return }
                    bridge.ready = { continuation.resume(with: $0) }
                    bridge.start()
                }
            }
        } onCancel: { bridge.close() }
        return (bridge, localPort)
    }

    func setFrameRate(_ value: Int) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.framesPerSecond = DesktopStreamSettings(framesPerSecond: value).frameRate
            if self.delay != nil {
                self.delay?.cancel(); self.delay = nil
                self.sendNext()
            }
        }
    }

    func close() { queue.async { [weak self] in self?.stop() } }

    /// Used when input awaits confirming pixels. A tiny nonincremental probe wakes
    /// an idle incremental request; the next normal request refreshes the view.
    /// There is no polling or extra full-screen traffic during normal movement.
    func requestFreshFrame() {
        queue.async { [weak self] in
            guard let self, !self.closed, self.lastFrameRequest != nil, !self.refreshNextFrame else { return }
            self.refreshNextFrame = true
            if !self.pending.contains(where: \.isFrameRequest) {
                self.pending.append(.init(data: Data([3, 0, 0, 0, 0, 0, 0, 1, 0, 1]), probe: true))
            }
            self.delay?.cancel(); self.delay = nil
            self.sendNext()
        }
    }

    private func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener?.port { self.finishReady(.success(Int(port.rawValue))) }
                case .failed(let error): self.finishReady(.failure(error)); self.stop()
                case .cancelled: self.finishReady(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: queue)
        } catch { finishReady(.failure(error)); stop() }
    }

    private func finishReady(_ result: Result<Int, Error>) {
        let completion = ready; ready = nil; completion?(result)
    }

    private func accept(_ client: NWConnection) {
        guard !closed, local == nil else { client.cancel(); return }
        local = client
        listener?.cancel() // This adapter serves one native viewer only.
        let server = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: upstreamPort)!, using: .tcp)
        remote = server
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        server.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.readClient(); self.readServer()
            case .failed: self.stop()
            default: break
            }
        }
        client.start(queue: queue)
        server.start(queue: queue)
    }

    private func readClient() {
        guard !closed, !receivingClient else { return }
        receivingClient = true
        local?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            self.receivingClient = false
            guard error == nil, !complete else { self.stop(); return }
            do {
                if let data {
                    for message in try self.parser.append(data) {
                        if message.isFrameRequest, let requestedAt = self.frameRequestedAt {
                            self.onFrameCompleted?(requestedAt)
                        }
                        self.pending.append(message)
                    }
                }
                guard self.pending.count <= 128 else { self.stop(); return }
                self.sendNext()
            } catch { self.stop() }
        }
    }

    private func sendNext() {
        guard !closed, !sending, delay == nil else { return }
        guard let message = pending.first else { readClient(); return }
        if message.isFrameRequest, let lastRequest {
            let deadline = lastRequest + 1 / Double(framesPerSecond)
            if deadline > .now() {
                let task = DispatchWorkItem { [weak self] in
                    guard let self, !self.closed else { return }
                    self.delay = nil; self.sendNext()
                }
                delay = task
                queue.asyncAfter(deadline: deadline, execute: task)
                return
            }
        }
        pending.removeFirst()
        var data = message.data
        if message.isFrameRequest {
            lastRequest = .now()
            if !message.probe {
                frameRequestedAt = ProcessInfo.processInfo.systemUptime
                lastFrameRequest = data
                if refreshNextFrame { data[1] = 0; refreshNextFrame = false }
            }
        }
        sending = true
        remote?.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.sending = false
            if error != nil { self.stop() } else { self.sendNext() }
        })
    }

    private func readServer() {
        guard !closed else { return }
        remote?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            guard error == nil, let data, !data.isEmpty else { self.stop(); return }
            self.local?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil || complete { self.stop() } else { self.readServer() }
            })
        }
    }

    private func stop() {
        guard !closed else { return }
        closed = true
        delay?.cancel(); delay = nil; pending.removeAll()
        listener?.cancel(); local?.cancel(); remote?.cancel()
        finishReady(.failure(CancellationError()))
    }
    deinit { delay?.cancel(); listener?.cancel(); local?.cancel(); remote?.cancel() }
}

/// Both desktop providers expose an authenticated SSH forward with RFB None
/// security inside it. Parse only its small client messages, never framebuffer
/// data. Bounds apply before waiting for variable-length payloads.
struct DesktopRFBRequests {
    struct Message {
        let data: Data
        var probe = false
        var isFrameRequest: Bool { data.first == 3 && data.count == 10 }
    }
    private enum Phase { case version, security, clientInit, messages }
    private var phase = Phase.version
    private var bytes: [UInt8] = []
    private let quality: DesktopStreamQuality

    init(quality: DesktopStreamQuality) { self.quality = quality }

    mutating func append(_ data: Data) throws -> [Message] {
        guard bytes.count + data.count <= 8192 else { throw invalid() }
        bytes.append(contentsOf: data)
        var result: [Message] = []
        while let message = try next() { result.append(Message(data: message)) }
        return result
    }

    private mutating func next() throws -> Data? {
        switch phase {
        case .version:
            guard bytes.count >= 12 else { return nil }
            let version = String(decoding: bytes.prefix(12), as: UTF8.self)
            guard ["RFB 003.003\n", "RFB 003.007\n", "RFB 003.008\n"].contains(version) else { throw invalid() }
            phase = version == "RFB 003.003\n" ? .clientInit : .security
            return take(12)
        case .security:
            guard let selection = bytes.first else { return nil }
            guard selection == 1 else { throw invalid() }
            phase = .clientInit; return take(1)
        case .clientInit:
            guard !bytes.isEmpty else { return nil }
            phase = .messages; return take(1)
        case .messages:
            guard let kind = bytes.first else { return nil }
            let count: Int
            switch kind {
            case 0: count = 20
            case 2:
                guard bytes.count >= 4 else { return nil }
                let encodings = Int(bytes[2]) << 8 | Int(bytes[3])
                guard encodings <= 128 else { throw invalid() }
                count = 4 + encodings * 4
            case 3: count = 10
            case 150: count = 10
            case 248:
                guard bytes.count >= 9 else { return nil }
                guard bytes[8] <= 64 else { throw invalid() }
                count = 9 + Int(bytes[8])
            default: throw invalid()
            }
            guard bytes.count >= count else { return nil }
            let message = take(count)
            if kind == 2 { return encodings(message) }
            if kind == 150 {
                // Continuous updates bypass request pacing. Never enable them.
                var disabled = message; disabled[1] = 0; return disabled
            }
            return message
        }
    }

    private func encodings(_ message: Data) -> Data {
        let wire = [UInt8](message)
        var values: [Int32] = []
        for offset in stride(from: 4, to: wire.count, by: 4) {
            let high = UInt32(wire[offset]) << 24 | UInt32(wire[offset + 1]) << 16
            let low = UInt32(wire[offset + 2]) << 8 | UInt32(wire[offset + 3])
            let value = Int32(bitPattern: high | low)
            if value != -313, !(-32 ... -23).contains(value), !(-512 ... -412).contains(value) { values.append(value) }
        }
        if let jpeg = quality.jpegQuality {
            values = Array(values.prefix(127)); values.append(-32 + jpeg)
        }
        var result = Data([2, 0, UInt8(values.count >> 8), UInt8(values.count & 255)])
        for value in values {
            let bits = UInt32(bitPattern: value)
            result.append(contentsOf: [UInt8(truncatingIfNeeded: bits >> 24), UInt8(truncatingIfNeeded: bits >> 16),
                                      UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits)])
        }
        return result
    }
    private mutating func take(_ count: Int) -> Data {
        let message = Data(bytes.prefix(count)); bytes.removeFirst(count); return message
    }
    private func invalid() -> DesktopProblem {
        DesktopProblem(code: "invalid_display", message: "The desktop stream could not be read. Reconnect to try again.")
    }
}
