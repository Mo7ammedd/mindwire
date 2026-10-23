import Foundation
import Observation
import Darwin
import NIOCore

@MainActor
protocol LocalPortListener: AnyObject {
    var port: Int { get }
    var isActive: Bool { get }
    func close()
}

extension SSHLocalForwarder: LocalPortListener {}

/// App-owned listeners; the daemon owns authorization, and the existing native
/// SSH forwarder carries bytes. No remote firewall or public port is changed.
@MainActor @Observable
final class ConnectionPortForwards {
    private(set) var sessions: [ConnectionPortForward] = []
    @ObservationIgnored private let network: ComputerNetworkMonitor
    @ObservationIgnored private weak var stores: Stores?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeSession: ((Connection, Int, Int) -> ConnectionPortForward)?
    @ObservationIgnored private var networkObservation: ComputerNetworkMonitor.Observation?
    @ObservationIgnored private var networkRevision: UInt64
    @ObservationIgnored private var active: Bool
    static let storageKey = "mindwire.connection.portForwards.v1"

    private struct SavedForward: Codable {
        let connectionId: String
        let remotePort: Int
        let localPort: Int
    }

    init(stores: Stores = .shared, network: ComputerNetworkMonitor = .shared,
         initiallyActive: Bool = true,
         makeSession: ((Connection, Int, Int) -> ConnectionPortForward)? = nil) {
        self.stores = stores; defaults = stores.defaults; self.network = network
        self.makeSession = makeSession; active = initiallyActive; networkRevision = network.state.revision
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([SavedForward].self, from: $0) } ?? []
        for entry in saved {
            guard (1...65535).contains(entry.remotePort), (0...65535).contains(entry.localPort),
                  let connection = stores.connections.get(entry.connectionId),
                  connection.pairedComputer != nil || connection.remote != nil,
                  !sessions.contains(where: { $0.connection.id == entry.connectionId && $0.remotePort == entry.remotePort }),
                  let session = createSession(connection: connection, port: entry.remotePort, localPort: entry.localPort) else { continue }
            sessions.append(session)
        }
        persist()
        if active { sessions.forEach { $0.start() } }
        networkObservation = network.observe { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, state.revision > self.networkRevision else { return }
                self.networkRevision = state.revision
                if self.active {
                    for session in self.sessions { session.pause(); session.start() }
                }
            }
        }
    }

    private func createSession(connection: Connection, port: Int, localPort: Int = 0) -> ConnectionPortForward? {
        guard let stores else { return nil }
        let session = makeSession?(connection, port, localPort)
            ?? ConnectionPortForward(connection: connection, port: port, network: network, stores: stores, localPort: localPort)
        session.portDidBind = { [weak self] in self?.persist() }
        return session
    }

    func setActive(_ next: Bool) {
        guard active != next else { return }
        active = next
        for session in sessions {
            if next { session.start() } else { session.pause() }
        }
    }

    private func persist() {
        guard !sessions.isEmpty else {
            if defaults.object(forKey: Self.storageKey) != nil { defaults.removeObject(forKey: Self.storageKey) }
            return
        }
        let saved = sessions.map {
            SavedForward(connectionId: $0.connection.id, remotePort: $0.remotePort, localPort: $0.preferredLocalPort)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(saved), data != defaults.data(forKey: Self.storageKey) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    @discardableResult func open(connection: Connection, port: Int) -> ConnectionPortForward {
        if let existing = sessions.first(where: { $0.connection.id == connection.id && $0.remotePort == port }) {
            if active { existing.start() }
            return existing
        }
        guard let session = createSession(connection: connection, port: port) else {
            preconditionFailure("A forwarding manager must belong to a live store.")
        }
        sessions.append(session)
        persist()
        if active { session.start() }
        return session
    }
    func close(_ session: ConnectionPortForward) {
        sessions.removeAll { $0.id == session.id }
        session.portDidBind = nil
        session.stop()
        persist()
    }
    func close(connectionId: String) {
        for session in sessions where session.connection.id == connectionId { close(session) }
    }
}

@MainActor @Observable
final class ConnectionPortForward: Identifiable {
    let id: String
    let connection: Connection
    let remotePort: Int
    private(set) var localPort: Int?
    private(set) var error: String?
    private(set) var connecting = true
    private(set) var connectionRevision = 0
    @ObservationIgnored private var forward: (any LocalPortListener)?
    @ObservationIgnored private var ssh: SSHConnection?
    @ObservationIgnored private var computer: ComputerDaemonChannel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var attempt: UUID?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var boundPort = 0
    @ObservationIgnored private let network: ComputerNetworkMonitor
    @ObservationIgnored private weak var stores: Stores?
    @ObservationIgnored private let desktopSessionId: String?
    @ObservationIgnored private var openingWaiters: [UUID: CheckedContinuation<Int, Error>] = [:]
    @ObservationIgnored private let makeListener: ((Int) async throws -> any LocalPortListener)?
    @ObservationIgnored var portDidBind: (() -> Void)?
    var preferredLocalPort: Int { boundPort }

    init(connection: Connection, port: Int, network: ComputerNetworkMonitor = .shared,
         stores: Stores = .shared, desktopSessionId: String? = nil, localPort: Int = 0,
         id: String? = nil,
         makeListener: ((Int) async throws -> any LocalPortListener)? = nil) {
        self.connection = connection; remotePort = port; self.network = network
        self.stores = stores; self.desktopSessionId = desktopSessionId
        boundPort = localPort; self.makeListener = makeListener
        // Reopening the app can renew its previous grant immediately, even if
        // iOS terminated it before it could send Close.
        self.id = id ?? desktopSessionId.map { "desktop-\($0)" }
            ?? connection.pairedComputer.map { "port-\($0.deviceId)-\(port)" } ?? UUID().uuidString
    }
    var url: URL? { localPort.flatMap { URL(string: "http://127.0.0.1:\($0)") } }

    /// The desktop and preview clients share grant acquisition, connection
    /// pooling and cleanup. Concurrent callers await the same opening attempt.
    func ready() async throws -> Int {
        try Task.checkCancellation()
        if let localPort, forward?.isActive == true { return localPort }
        guard !stopped else { throw CancellationError() }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                openingWaiters[waiter] = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor in self.openingWaiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError()) }
        }
    }

    private func finishOpening(_ result: Result<Int, Error>) {
        let pending = openingWaiters.values
        openingWaiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }

    func start() {
        guard task == nil, !stopped else { return }
        connecting = true; error = nil
        let attempt = UUID()
        self.attempt = attempt
        let job = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tasks[attempt] = nil
                if self.attempt == attempt { self.task = nil; self.attempt = nil }
            }
            while !Task.isCancelled, !self.stopped, self.attempt == attempt {
                do {
                    var opened: (any LocalPortListener)?
                    if let makeListener = self.makeListener {
                        if self.forward?.isActive != true { opened = try await self.openListener(makeListener) }
                    } else if let paired = self.connection.pairedComputer, let stores = self.stores {
                        if self.computer == nil { self.computer = ComputerDaemonChannel(computer: paired, network: self.network, stores: stores) }
                        let channel = self.computer!
                        let http = DaemonHTTP(channel: channel, agentType: "")
                        var grant: [String: Any] = [
                            "id": self.id, "deviceId": paired.deviceId, "port": self.remotePort
                        ]
                        if let desktopSessionId = self.desktopSessionId { grant["desktopSessionId"] = desktopSessionId }
                        _ = try await http.run("POST", "/computer/forwards", json: grant, quiet: true)
                        try Task.checkCancellation()
                        if self.forward?.isActive != true {
                            opened = try await self.openListener { try await channel.forwardLocal(port: self.remotePort, localPort: $0) }
                        }
                    } else if let remote = self.connection.remote {
                        if self.ssh == nil { self.ssh = SSHConnection.make(for: remote) }
                        if self.forward?.isActive != true {
                            let ssh = self.ssh!
                            opened = try await self.openListener {
                                try await ssh.forwardLocal(host: "127.0.0.1", port: self.remotePort, localPort: $0)
                            }
                        }
                    } else { throw ComputerConnectionError.notPaired }
                    guard !Task.isCancelled, !self.stopped, self.attempt == attempt else { opened?.close(); return }
                    if let opened { self.forward = opened; self.connectionRevision += 1 }
                    self.localPort = self.forward?.port
                    let previousPort = self.boundPort
                    self.boundPort = self.forward?.port ?? self.boundPort
                    if previousPort != self.boundPort { self.portDidBind?() }
                    self.connecting = false; self.error = nil
                    if let port = self.localPort { self.finishOpening(.success(port)) }
                    // Renew explicit computer grants before their two-minute expiry.
                    for _ in 0..<30 {
                        try await Task.sleep(for: .seconds(1))
                        guard self.forward?.isActive == true else { throw ComputerConnectionError.unreachable }
                    }
                } catch {
                    guard self.attempt == attempt else { return }
                    self.finishOpening(.failure(error))
                    if Task.isCancelled || self.stopped { self.forward?.close(); return }
                    self.forward?.close(); self.forward = nil; self.localPort = nil
                    self.connecting = false
                    if let api = error as? DaemonHTTPError, (400..<500).contains(api.status) {
                        self.error = api.status == 404
                            ? "Update Mindwire on this computer to use private port forwarding."
                            : api.localizedDescription
                        return
                    }
                    self.error = error.localizedDescription
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self.connecting = true
                }
            }
        }
        task = job
        tasks[attempt] = job
    }

    private func openListener(_ make: (Int) async throws -> any LocalPortListener) async throws -> any LocalPortListener {
        do { return try await make(boundPort) }
        catch let error as IOError where error.errnoCode == EADDRINUSE && boundPort != 0 {
            try Task.checkCancellation()
            return try await make(0)
        }
    }

    /// Suspend only this listener. Keep its address and grant identity for the next foreground.
    func pause() {
        attempt = nil
        task?.cancel(); task = nil
        forward?.close(); forward = nil
        ssh?.close(); ssh = nil
        localPort = nil; connecting = false
        finishOpening(.failure(CancellationError()))
    }

    func stop() {
        stopped = true
        let opening = Array(tasks.values)
        pause()
        if let computer {
            let id = self.id
            Task {
                // A grant response may be in flight when Close is pressed. Revoke
                // after it settles, so a late reply cannot resurrect a forward.
                for job in opening { await job.value }
                _ = try? await DaemonHTTP(channel: computer, agentType: "").run("DELETE", "/computer/forwards/\(id)", json: nil, quiet: true)
                await computer.close()
            }
            self.computer = nil
        }
    }
}
