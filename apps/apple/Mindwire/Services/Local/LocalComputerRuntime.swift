#if targetEnvironment(macCatalyst)
import Darwin
import Foundation
import Security

/// Reuses the computer CLI's state and running service. A fresh installation starts
/// the signed helper included in the app; opening a window never replaces a service.
actor LocalComputerRuntime {
    static let shared = LocalComputerRuntime()

    struct Endpoint: Sendable {
        let computerId: String
        let pid: Int32
        let url: URL
        let token: String
        let desktopToken: String?
        let home: String
    }
    private struct Descriptor: Decodable {
        let computerId: String
        let pid: Int32
        let apiAddress: String
    }
    private var cached: Endpoint?
    private var cachedAt = Date.distantPast
    private var connecting: Task<Endpoint, Error>?

    static var home: URL {
        guard let directory = getpwuid(getuid())?.pointee.pw_dir else {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }
    private var directory: URL { Self.home.appendingPathComponent(".mindwire/computer", isDirectory: true) }

    func endpoint(computerId: String, refresh: Bool = false) throws -> Endpoint {
        let value: Endpoint
        if !refresh, let cached, Date().timeIntervalSince(cachedAt) < 1 { value = cached }
        else {
            value = try readEndpoint()
            cached = value
            cachedAt = Date()
        }
        guard value.computerId == computerId else {
            throw BackendError.message("This workspace belongs to a different Mac.")
        }
        return value
    }

    func connect() async throws -> Endpoint {
        if let connecting { return try await connecting.value }
        let task = Task { try await self.open() }
        connecting = task
        defer { connecting = nil }
        return try await task.value
    }

    private func open() async throws -> Endpoint {
        if let current = try? readEndpoint() {
            do { return try await verify(current) }
            catch {
                // An alive service may be starting or temporarily unavailable. Never
                // kill it, rotate its token, or start a second service against its DB.
                if kill(current.pid, 0) == 0 || errno == EPERM {
                    throw BackendError.message("Mindwire on this Mac is not responding yet. Try again in a moment.")
                }
            }
        }
        try startBundledService()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        while clock.now < deadline {
            try Task.checkCancellation()
            if let value = try? readEndpoint(), let ready = try? await verify(value) { return ready }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw BackendError.message("Mindwire couldn't start on this Mac. Check ~/.mindwire/computer/desktop-app.log.")
    }

    private func verify(_ endpoint: Endpoint) async throws -> Endpoint {
        struct Identity: Decodable { let computerId: String; let pid: Int32 }
        var request = URLRequest(url: endpoint.url.appendingPathComponent("computer"))
        request.timeoutInterval = 3
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await LocalRuntimeSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BackendError.message("The local Mindwire service couldn't be authenticated.")
        }
        let identity = try JSONDecoder().decode(Identity.self, from: data)
        guard identity.computerId == endpoint.computerId, identity.pid == endpoint.pid else {
            throw BackendError.message("The local Mindwire service changed. Try again.")
        }
        cached = endpoint
        cachedAt = Date()
        return endpoint
    }

    private func readEndpoint() throws -> Endpoint {
        let file = directory.appendingPathComponent("computer-runtime.json")
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: readPrivateFile(file, maximum: 65_536))
        guard !descriptor.computerId.isEmpty, descriptor.computerId.count <= 200, descriptor.pid > 1,
              let parts = URLComponents(string: "http://" + descriptor.apiAddress),
              ["127.0.0.1", "[::1]", "::1"].contains(parts.host ?? ""),
              let port = parts.port, (1...65_535).contains(port),
              parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil, let url = parts.url else {
            throw BackendError.message("Invalid local Mindwire service address.")
        }
        let token = try credential("daemon.token")
        let desktopToken = try? credential("desktop-control.token")
        return .init(computerId: descriptor.computerId, pid: descriptor.pid, url: url,
                     token: token, desktopToken: desktopToken, home: Self.home.path)
    }

    private func credential(_ name: String) throws -> String {
        let data = try readPrivateFile(directory.appendingPathComponent(name), maximum: 4_096)
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains(where: \.isWhitespace) else {
            throw BackendError.message("Invalid local Mindwire credential.")
        }
        return value
    }

    private func readPrivateFile(_ url: URL, maximum: Int) throws -> Data {
        // Open the exact owner-only file; reject symlinks and bound reads before decoding.
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG, status.st_mode & 0o077 == 0,
              status.st_size > 0, status.st_size <= maximum else {
            throw BackendError.message("Mindwire's local service files must be private to your Mac account.")
        }
        return try handle.read(upToCount: maximum) ?? Data()
    }

    private func startBundledService() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mindwired")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw BackendError.message("This Mindwire build is missing its local runtime.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tokenURL = directory.appendingPathComponent("daemon.token")
        if !FileManager.default.fileExists(atPath: tokenURL.path) {
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw BackendError.message("Couldn't create the local runtime credential.")
            }
            let token = random.map { String(format: "%02x", $0) }.joined()
            let fd = Darwin.open(tokenURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if fd >= 0 {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data(token.utf8))
            } else if errno != EEXIST {
                throw BackendError.message("Couldn't save the local runtime credential.")
            }
        }
        let token = try credential("daemon.token")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = Self.home.path
        environment["DAEMON_TOKEN"] = token
        environment["STATE_PATH"] = directory.appendingPathComponent("agent-state.json").path
        environment["WORKSPACE_DB_PATH"] = directory.appendingPathComponent("workspace.db").path
        environment["AGENT_CWD"] = Self.home.path
        environment["ADDR"] = "127.0.0.1:0"
        environment["COMPUTER_SSH_ADDR"] = "127.0.0.1:0"
        environment["COMPUTER_WS_ADDR"] = "127.0.0.1:0"
        let arguments = ["/bin/zsh", "-l", "-c", "cd \"$HOME\" && exec \"$1\" --computer", "mindwire-desktop", helper.path]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv + envp { if let value { free(value) } } }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        let log = directory.appendingPathComponent("desktop-app.log").path
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&child, "/bin/zsh", &actions, nil, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw BackendError.message("Couldn't start Mindwire on this Mac.") }
        // Reap only our child; it outlives windows and is never stopped by navigation.
        Task.detached(priority: .utility) {
            var status: Int32 = 0
            while waitpid(child, &status, WNOHANG) == 0 {
                try await Task.sleep(for: .seconds(30))
            }
        }
    }
}

private final class LocalRuntimeSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One bounded pool for local chat, metadata and terminal traffic. Long SSE reads
/// leave capacity for navigation requests; no session or URL cache per view.
private enum LocalRuntimeSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 32
        return URLSession(configuration: configuration, delegate: LocalRuntimeSessionDelegate(), delegateQueue: nil)
    }()
}

/// Same request builder, HTTP error handling and SSE decoder as cloud / paired hosts.
struct LocalDaemonChannel: StreamingDaemonChannel {
    let label = "local"
    private let channel: URLSessionDaemonChannel
    init(computerId: String) {
        channel = URLSessionDaemonChannel(label: "local", session: LocalRuntimeSession.shared) { method, path, body, refresh in
            let endpoint = try await LocalComputerRuntime.shared.endpoint(computerId: computerId, refresh: refresh)
            guard path.hasPrefix("/"), !path.hasPrefix("//"),
                  let url = URL(string: endpoint.url.absoluteString + path),
                  url.host == endpoint.url.host, url.port == endpoint.url.port else {
                throw BackendError.message("Invalid local runtime request.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
            if path.hasPrefix("/surfaces/desktop/local"), let desktopToken = endpoint.desktopToken {
                request.setValue(desktopToken, forHTTPHeaderField: "X-Mindwire-Local-Control")
            }
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            return request
        }
    }
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        try await channel.perform(method: method, path: path, jsonBody: jsonBody)
    }
    func stream(method: String, path: String, jsonBody: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        try await channel.stream(method: method, path: path, jsonBody: jsonBody)
    }
}
#endif
