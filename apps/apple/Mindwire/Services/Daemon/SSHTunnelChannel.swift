import Foundation

/// Native HTTP and SSE over a loopback-only SSH direct-tcpip forward. All daemon
/// APIs share the same transport/parser as cloud, including live tools and approvals.
struct SSHTunnelChannel: StreamingDaemonChannel {
    private let endpoint: SSHDaemonEndpoint
    var label: String { "ssh-tunnel" }

    init(ssh: SSHConnection, port: Int = AppConstants.daemonPort, token: String? = nil) {
        self.init(ssh: ssh, token: token, resolvePort: { port })
    }

    /// Container backends resolve Docker's loopback publication when opening the tunnel.
    init(ssh: SSHConnection, token: String?, resolvePort: @escaping @Sendable () async throws -> Int) {
        endpoint = SSHDaemonEndpoint(token: token) {
            try await ssh.forwardLocal(host: "127.0.0.1", port: resolvePort())
        }
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        let connection = try await endpoint.open()
        do { return try await connection.http.perform(method: method, path: path, jsonBody: jsonBody) }
        catch {
            if !Task.isCancelled { await endpoint.invalidate(connection) }
            // Do not replay a mutation after an ambiguous disconnect. The operation/run
            // reconciliation above this transport decides whether it was already accepted.
            throw error
        }
    }

    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        let connection = try await endpoint.open()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let source = try await connection.http.stream(method: method, path: path, jsonBody: jsonBody)
                    for try await event in source { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    // Closing one chat must not close another chat or a control request.
                    if !Task.isCancelled,
                       !connection.forward.isActive || (error as NSError).domain == NSURLErrorDomain {
                        await endpoint.invalidate(connection)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor SSHDaemonEndpoint {
    struct Connection {
        let id = UUID()
        let forward: SSHLocalForwarder
        let http: URLSessionDaemonChannel
    }

    private let token: String?
    private let makeForward: @Sendable () async throws -> SSHLocalForwarder
    private var connection: Connection?
    private var opening: Task<Connection, Error>?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 300
        return URLSession(configuration: configuration)
    }()

    init(token: String?, makeForward: @escaping @Sendable () async throws -> SSHLocalForwarder) {
        self.token = token
        self.makeForward = makeForward
    }

    deinit { connection?.forward.close(); opening?.cancel() }

    func open() async throws -> Connection {
        if let connection, connection.forward.isActive { return connection }
        connection?.forward.close()
        connection = nil
        if let opening { return try await opening.value }
        let token = self.token, makeForward = self.makeForward
        let opening = Task {
            let forward = try await makeForward()
            do { try Task.checkCancellation() }
            catch { forward.close(); throw error }
            let base = "http://127.0.0.1:\(forward.port)"
            let http = URLSessionDaemonChannel(label: "ssh-tunnel", session: Self.session) { method, path, body, _ in
                guard path.hasPrefix("/"), !path.hasPrefix("//"), let url = URL(string: base + path),
                      url.host == "127.0.0.1", url.port == forward.port else {
                    throw BackendError.message("Invalid Mindwire request path")
                }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
                request.httpMethod = method
                if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                if let body {
                    request.httpBody = body
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                return request
            }
            return Connection(forward: forward, http: http)
        }
        self.opening = opening
        do {
            let result = try await opening.value
            self.opening = nil
            connection = result
            return result
        } catch {
            self.opening = nil
            throw error
        }
    }

    func invalidate(_ failed: Connection) {
        failed.forward.close()
        if connection?.id == failed.id { connection = nil }
    }
}
