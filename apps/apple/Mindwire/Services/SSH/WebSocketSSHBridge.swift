import Foundation
import Network

/// Adapts a provider's WebSocket byte stream to native NIOSSH. The local listener is
/// loopback-only; SSH still verifies the computer and encrypts every workspace byte.
// Mutable listener/peer state is confined to queue; URLSession and NWConnection
// provide their own thread safety for the immutable handles used by async tasks.
final class WebSocketSSHBridge: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "mindwire.ssh.websocket")
    private var listener: NWListener?
    private var peer: Peer?
    private var stopped = false
    private let failureLock = NSLock()
    private var recordedFailure: Error?

    var failure: Error? { failureLock.withLock { recordedFailure } }

    private func recordFailure(_ error: Error) {
        failureLock.withLock { if recordedFailure == nil { recordedFailure = error } }
    }

    init(url: URL) { self.url = url }

    func open() async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        var finished = false
                        func finish(_ result: Result<Int, Error>) {
                            guard !finished else { return }; finished = true
                            continuation.resume(with: result)
                        }
                        listener.stateUpdateHandler = { [weak listener] state in
                            switch state {
                            case .ready:
                                if let port = listener?.port { finish(.success(Int(port.rawValue))) }
                            case .failed(let error): finish(.failure(error))
                            case .cancelled: finish(.failure(CancellationError()))
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self, !self.stopped, self.peer == nil else { connection.cancel(); return }
                            let peer = Peer(connection: connection, url: self.url, queue: self.queue) { [weak self] error in
                                self?.recordFailure(error)
                            }
                            self.peer = peer
                            peer.start()
                        }
                        listener.start(queue: queue)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.close() }
    }

    func close() {
        queue.async { [self] in
            guard !stopped else { return }; stopped = true
            listener?.cancel(); listener = nil
            peer?.close(); peer = nil
        }
    }

    private final class Peer: @unchecked Sendable {
        let connection: NWConnection
        let queue: DispatchQueue
        let session: URLSession
        let websocket: URLSessionWebSocketTask
        let onFailure: @Sendable (Error) -> Void
        var receiving: Task<Void, Never>?
        var pinging: Task<Void, Never>?
        var pingDeadline: DispatchWorkItem?
        var closed = false

        init(connection: NWConnection, url: URL, queue: DispatchQueue, onFailure: @escaping @Sendable (Error) -> Void) {
            self.connection = connection; self.queue = queue
            self.onFailure = onFailure
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: config)
            websocket = session.webSocketTask(with: url)
            websocket.maximumMessageSize = 1 << 20
        }
        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.websocket.resume()
                    self.readLocal()
                    self.receiving = Task { [weak self] in
                        guard let self else { return }
                        do {
                            while !Task.isCancelled {
                                guard case .data(let bytes) = try await self.websocket.receive() else {
                                    throw BackendError.message("The computer tunnel returned invalid data.")
                                }
                                try await self.sendLocal(bytes)
                            }
                        } catch { self.queue.async { self.fail(error) } }
                    }
                    self.pinging = Task { [weak self] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(20)) } catch { return }
                            guard let self else { return }
                            self.queue.async {
                                guard !self.closed, self.pingDeadline == nil else { return }
                                let deadline = DispatchWorkItem { [weak self] in self?.fail(URLError(.timedOut)) }
                                self.pingDeadline = deadline
                                self.queue.asyncAfter(deadline: .now() + 10, execute: deadline)
                                self.websocket.sendPing { error in
                                    self.queue.async {
                                        self.pingDeadline?.cancel(); self.pingDeadline = nil
                                        if let error { self.fail(error) }
                                    }
                                }
                            }
                        }
                    }
                case .failed, .cancelled: self.close()
                default: break
                }
            }
            connection.start(queue: queue)
        }
        func readLocal() {
            guard !closed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
                guard let self else { return }
                guard error == nil, let data, !data.isEmpty else { self.close(); return }
                Task {
                    do {
                        try await self.websocket.send(.data(data))
                        self.queue.async { if done { self.close() } else { self.readLocal() } }
                    } catch { self.queue.async { self.fail(error) } }
                }
            }
        }
        func sendLocal(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }
        func fail(_ error: Error) {
            guard !closed else { return }
            let cause = error as NSError
            if cause.domain == NSURLErrorDomain,
               [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(cause.code) {
                onFailure(ComputerConnectionError.internetAddressUnavailable)
            } else {
                onFailure(ComputerConnectionError.tunnelUnavailable)
            }
            close()
        }
        func close() {
            guard !closed else { return }; closed = true
            receiving?.cancel(); receiving = nil; pinging?.cancel(); pinging = nil
            pingDeadline?.cancel(); pingDeadline = nil
            connection.cancel(); websocket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel()
        }
    }
}
