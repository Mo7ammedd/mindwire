import Foundation

final class ComputerSSHLink {
    let id = UUID()
    let ssh: SSHConnection
    let channel: SSHTunnelChannel
    init(route: ComputerRoute, username: String, auth: SSHConnection.Auth, fingerprint: String, port: Int, token: String?) {
        ssh = SSHConnection(host: route.host ?? "127.0.0.1", port: route.port ?? 8791,
                            username: username, auth: auth, expectedHostKey: fingerprint,
                            websocketURL: route.kind == "websocket" ? route.url.flatMap(URL.init(string:)) : nil,
                            connectTimeoutSeconds: 12)
        channel = SSHTunnelChannel(ssh: ssh, port: port, token: token)
    }
    deinit { ssh.close() }

    /// Race authenticated connections, then close every unused route. No API mutation
    /// is sent during route selection, so failover can't repeat a command or message.
    static func open(routes: [ComputerRoute], username: String, auth: SSHConnection.Auth,
                     fingerprint: String, port: Int, token: String?, attempts: Int = 1,
                     onAttempt: (@Sendable (Int, Int) async -> Void)? = nil) async throws -> ComputerSSHLink {
        for attempt in 0..<max(1, attempts) {
            await onAttempt?(attempt + 1, max(1, attempts))
            do {
                return try await openOnce(routes: routes, username: username, auth: auth,
                                          fingerprint: fingerprint, port: port, token: token)
            } catch {
                try Task.checkCancellation()
                guard attempt + 1 < attempts,
                      (error as? ComputerConnectionError)?.canRetryConnection == true else { throw error }
                // Only the handshake is retried. No workspace operation has been
                // sent, so this shared recovery cannot duplicate a user action.
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw ComputerConnectionError.unreachable
    }

    private static func openOnce(routes: [ComputerRoute], username: String, auth: SSHConnection.Auth,
                                 fingerprint: String, port: Int, token: String?) async throws -> ComputerSSHLink {
        guard !routes.isEmpty, routes.allSatisfy(\.isValid) else { throw ComputerConnectionError.notPaired }
        let links = routes.map { ComputerSSHLink(route: $0, username: username, auth: auth, fingerprint: fingerprint, port: port, token: token) }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Result<ComputerSSHLink, Error>.self) { group in
                for link in links {
                    group.addTask {
                        do { try await link.ssh.authenticate(); try Task.checkCancellation(); return .success(link) }
                        catch { link.ssh.close(); return .failure(error) }
                    }
                }
                var failures: [Error] = []
                for try await result in group {
                    switch result {
                    case .success(let selected):
                        group.cancelAll()
                        for link in links where link !== selected { link.ssh.close() }
                        return selected
                    case .failure(let error): failures.append(error)
                    }
                }
                try Task.checkCancellation()
                throw connectionFailure(failures)
            }
        } onCancel: { for link in links { link.ssh.close() } }
    }

    static func connectionFailure(_ failures: [Error]) -> ComputerConnectionError {
        if failures.contains(where: { $0 is SSHIdentityError }) { return .identityChanged }
        for failure in failures {
            if let failure = failure as? SSHAuthenticationError {
                switch failure {
                case .keyRejected: return .notPaired
                case .passwordRejected: return .codeRejected
                }
            }
        }
        // A rejected key or a changed host is actionable even when another route
        // times out. Don't tell an already reachable owner to check their Wi-Fi.
        let errors = failures.compactMap { $0 as? ComputerConnectionError }
        if let error = errors.first(where: { !$0.canRetryConnection }) { return error }
        if errors.contains(.internetAddressUnavailable) { return .internetAddressUnavailable }
        if errors.contains(.tunnelUnavailable) { return .tunnelUnavailable }
        return .unreachable
    }
}

/// Workspace, chat and terminal clients share this channel and the existing HTTP/SSE parser.
final class ComputerDaemonChannel: StreamingDaemonChannel {
    let label = "computer-ssh"
    private let endpoint: ComputerEndpoint
    private let lease: ComputerEndpointLease
    init(computer: PairedComputer, network: ComputerNetworkMonitor = .shared, stores: Stores = .shared) {
        lease = ComputerEndpointPool.shared.acquire(computer, network: network, stores: stores)
        endpoint = lease.endpoint
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        let link = try await lease.open()
        do { return try await link.channel.perform(method: method, path: path, jsonBody: jsonBody) }
        catch {
            try Task.checkCancellation()
            await endpoint.invalidate(link)
            // A sleeping computer can leave a stale socket which still looks
            // connected. Retry a read once through a fresh, verified connection.
            // Mutation receipts remain owned by callers; never replay a write here.
            guard method == "GET" || method == "HEAD" else { throw error }
            let replacement = try await lease.open()
            do { return try await replacement.channel.perform(method: method, path: path, jsonBody: jsonBody) }
            catch {
                if !Task.isCancelled { await endpoint.invalidate(replacement) }
                throw error
            }
        }
    }
    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        let link = try await lease.open()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let source = try await link.channel.stream(method: method, path: path, jsonBody: jsonBody)
                    for try await data in source { continuation.yield(data) }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled, !link.ssh.isConnected || (error as NSError).domain == NSURLErrorDomain {
                        await self.endpoint.invalidate(link)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func close() async {
        if let endpoint = lease.release() { await endpoint.close() }
    }
    func reconnect() async { await endpoint.disconnect() }

    /// The caller first acquires a device-bound grant from /computer/forwards.
    /// It then uses the same pinned SSH link as workspace and terminal requests.
    func forwardLocal(port: Int, localPort: Int = 0) async throws -> SSHLocalForwarder {
        let link = try await lease.open()
        return try await link.ssh.forwardLocal(host: "127.0.0.1", port: port, localPort: localPort)
    }

}

/// Views lease one pinned SSH endpoint per pairing. Closing a file browser must
/// not cancel the chat/terminal's connection or another caller's shared handshake.
private final class ComputerEndpointLease: @unchecked Sendable {
    let endpoint: ComputerEndpoint
    private let lock = NSLock()
    private var releaseAction: (() -> ComputerEndpoint?)?
    init(endpoint: ComputerEndpoint, release: @escaping () -> ComputerEndpoint?) {
        self.endpoint = endpoint; releaseAction = release
    }
    func open() async throws -> ComputerSSHLink {
        guard lock.withLock({ releaseAction != nil }) else { throw CancellationError() }
        return try await endpoint.open()
    }
    func release() -> ComputerEndpoint? {
        let action = lock.withLock { let action = releaseAction; releaseAction = nil; return action }
        return action?()
    }
    deinit { if let endpoint = release() { Task { await endpoint.close() } } }
}

private final class ComputerEndpointPool: @unchecked Sendable {
    static let shared = ComputerEndpointPool()
    private struct Key: Hashable {
        let computer: String, registry: String, device: String, fingerprint: String, key: String, token: String
        let network: ObjectIdentifier
        let stores: ObjectIdentifier
        init(_ computer: PairedComputer, network: ComputerNetworkMonitor, stores: Stores) {
            self.computer = computer.computerId; registry = computer.registryId; device = computer.deviceId
            fingerprint = computer.fingerprint; key = computer.keyRef; token = computer.tokenRef
            self.network = ObjectIdentifier(network)
            self.stores = ObjectIdentifier(stores)
        }
    }
    private final class Entry {
        let endpoint: ComputerEndpoint
        let observation: ComputerNetworkMonitor.Observation
        let connectionObserver: NSObjectProtocol
        var clients = 0
        init(_ computer: PairedComputer, network: ComputerNetworkMonitor, stores: Stores) {
            let endpoint = ComputerEndpoint(computer: computer, network: network, stores: stores)
            self.endpoint = endpoint
            observation = network.observe { [weak endpoint] state in Task { await endpoint?.networkChanged(state) } }
            connectionObserver = NotificationCenter.default.addObserver(forName: .computerConnectionChanged, object: nil, queue: nil) { [weak endpoint] event in
                guard event.userInfo?["computerId"] as? String == computer.computerId else { return }
                let removed = event.userInfo?["removed"] as? Bool == true
                Task { if removed { await endpoint?.close() } else { await endpoint?.disconnect() } }
            }
        }
        deinit { observation.cancel(); NotificationCenter.default.removeObserver(connectionObserver) }
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    func acquire(_ computer: PairedComputer, network: ComputerNetworkMonitor, stores: Stores) -> ComputerEndpointLease {
        let key = Key(computer, network: network, stores: stores)
        let entry = lock.withLock {
            let entry = entries[key] ?? Entry(computer, network: network, stores: stores)
            entry.clients += 1; entries[key] = entry
            return entry
        }
        return ComputerEndpointLease(endpoint: entry.endpoint) { [self] in
            lock.withLock {
                guard let existing = entries[key], existing === entry else { return nil }
                existing.clients -= 1
                guard existing.clients == 0 else { return nil }
                entries[key] = nil
                return existing.endpoint
            }
        }
    }
}

private actor ComputerEndpoint {
    struct Opening {
        let id = UUID()
        let generation: Int
        let task: Task<ComputerSSHLink, Error>
    }
    let computer: PairedComputer
    let network: ComputerNetworkMonitor
    let stores: Stores
    var networkRevision: UInt64
    var current: ComputerSSHLink?
    var opening: Opening?
    var closed = false
    var generation = 0
    init(computer: PairedComputer, network: ComputerNetworkMonitor, stores: Stores) {
        self.computer = computer; self.network = network; self.stores = stores; networkRevision = network.state.revision
    }
    func open() async throws -> ComputerSSHLink {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        networkChanged(network.state)
        if let current {
            if current.ssh.isConnected { return current }
            invalidate(current)
        }
        let attempt: Opening
        if let opening { attempt = opening }
        else {
            guard let key = SSHKey.loadPrivateKey(computer.keyRef),
                  let token = Keychain.get(computer.tokenRef), !token.isEmpty else { throw ComputerConnectionError.notPaired }
            attempt = Opening(generation: generation, task: Task {
                // Waiting offline belongs to this shared attempt too, so Close
                // cancels it and simultaneous callers don't create extra waits.
                try await network.waitUntilReachable()
                let routes = await stores.computerRoutes(for: computer)
                let link = try await ComputerDirectoryService.open(computer, routes: routes, key: key, token: token, stores: stores)
                do {
                    // Learn addresses only through the pinned, authenticated connection.
                    // This is a read, before any caller's operation can be delivered.
                    let result = try await link.channel.perform(method: "GET", path: "/computer", jsonBody: nil)
                    guard result.status == 200,
                          let info = try? JSONDecoder().decode(ComputerConnectionInfo.self, from: Data(result.body.utf8)),
                          info.matches(computer) else { throw ComputerConnectionError.notPaired }
                    try Task.checkCancellation()
                    await stores.updateComputerRoutes(info.routes, for: computer, policy: info.connection)
                    _ = try? await ComputerDirectoryService.learn(info, over: link.channel, computer: computer, stores: stores)
                    try Task.checkCancellation()
                    return link
                } catch { link.ssh.close(); throw error }
            })
            opening = attempt
        }
        do {
            let link = try await attempt.task.value
            guard !closed, attempt.generation == generation else { link.ssh.close(); throw ComputerConnectionError.unreachable }
            if opening?.id == attempt.id {
                opening = nil
                NotificationCenter.default.post(name: .computerTransportRecovered, object: nil,
                    userInfo: ["computer": computer])
            }
            current = link
            try Task.checkCancellation()
            return link
        } catch {
            // A cancelled attempt must not erase the new attempt opened on foreground.
            if opening?.id == attempt.id { opening = nil }
            if !closed, !Task.isCancelled, attempt.generation != generation {
                // No caller request was sent. Join the new connection after a handoff.
                return try await open()
            }
            if !closed, !Task.isCancelled, !(error is CancellationError) {
                NotificationCenter.default.post(name: .computerTransportFailed, object: nil,
                    userInfo: ["computer": computer, "error": error])
            }
            throw error
        }
    }
    func networkChanged(_ state: ComputerNetworkMonitor.State) {
        guard state.revision > networkRevision else { return }
        networkRevision = state.revision
        disconnect()
    }
    func invalidate(_ link: ComputerSSHLink) {
        guard current?.id == link.id else { return }
        generation += 1; current = nil; link.ssh.close()
        NotificationCenter.default.post(name: .computerTransportFailed, object: nil,
            userInfo: ["computer": computer, "error": ComputerConnectionError.unreachable])
    }
    func disconnect() { generation += 1; opening?.task.cancel(); opening = nil; current?.ssh.close(); current = nil }
    func close() { closed = true; disconnect() }
    deinit { opening?.task.cancel(); current?.ssh.close() }
}
