import XCTest
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
@testable import Mindwire

@MainActor
final class SSHTransportTests: XCTestCase {
    func testInstallerReportsLiveDownloadOverNativeSSHAndSurvivesLeavingTheScreen() async throws {
        let fixture = try await SSHHTTPFixture.start()
        addTeardownBlock { await fixture.stop() }
        let ssh = fixture.connection()
        defer { ssh.close() }
        let service = SelfHostedWorkspaceService(ssh: ssh)
        let coordinator = DaemonWorkCoordinator()
        let key = DaemonWorkKey(workspaceId: UUID().uuidString)
        let installation = Task {
            try await coordinator.perform(key, activity: .updatingDaemon) { work in
                try await ExecDaemonInstaller(workspace: service).install(agentType: "", cwd: "", target: "0.1.22",
                    daemonToken: SSHHTTPFixture.token, onProgress: work.progressHandler())
                work.receive(.verifying)
            }
        }
        try await eventually { coordinator.states[key]?.progressFraction == 0.625 }
        XCTAssertEqual(fixture.activeStreams, 1, "Progress must arrive while the installation is still running")
        XCTAssertEqual(coordinator.states[key]?.installProgress?.label, t("workspace.daemon.progress.downloading"))
        installation.cancel()
        let reopened = Task {
            try await coordinator.perform(key) { _ in XCTFail("Reopening must share the live installation") }
        }
        let http = DaemonHTTP(channel: SSHTunnelChannel(ssh: ssh, token: SSHHTTPFixture.token), agentType: "")
        let health: DaemonHealth = try await http.decode("GET", "/healthz")
        XCTAssertTrue(health.ok, "A download must not block native control requests on the same SSH connection")
        XCTAssertEqual(fixture.activeStreams, 1)
        fixture.finish()
        try await installation.value
        try await reopened.value
        XCTAssertEqual(coordinator.states[key]?.installProgress?.label, t("workspace.daemon.progress.verifying"))
        XCTAssertEqual(coordinator.states[key]?.running, false)
        XCTAssertEqual(fixture.installations, 1, "Joining the update must share one download and installation")
        XCTAssertEqual(fixture.connections, 1)
    }

    func testCancellingExecStreamOnlyClosesItsOwnSSHChannel() async throws {
        let fixture = try await SSHHTTPFixture.start()
        addTeardownBlock { await fixture.stop() }
        let ssh = fixture.connection()
        defer { ssh.close() }
        let stream = Task { for try await _ in ssh.execStream(["fixture-install"]) {} }
        try await eventually { fixture.activeStreams == 1 }
        stream.cancel()
        _ = try? await stream.value
        try await eventually { fixture.activeStreams == 0 }
        let http = DaemonHTTP(channel: SSHTunnelChannel(ssh: ssh, token: SSHHTTPFixture.token), agentType: "")
        let health: DaemonHealth = try await http.decode("GET", "/healthz")
        XCTAssertTrue(health.ok)
        XCTAssertEqual(fixture.connections, 1)
    }

    func testNativeRequestsAndConcurrentStreamsShareTunnelWithoutWaitingForCompletion() async throws {
        let fixture = try await SSHHTTPFixture.start()
        addTeardownBlock { await fixture.stop() }
        let ssh = fixture.connection()
        defer { ssh.close() }
        let channel = SSHTunnelChannel(ssh: ssh, token: SSHHTTPFixture.token)
        let http = DaemonHTTP(channel: channel, agentType: "codex")
        let first = expectation(description: "Every chat emits before its response finishes")
        first.expectedFulfillmentCount = 8
        let tasks = (0..<8).map { index in
            Task { () throws -> [DaemonEvent] in
                let stream = try XCTUnwrap(http.stream("/stream/\(index)"))
                var received: [DaemonEvent] = []
                for try await event in stream {
                    received.append(event)
                    if received.count == 1 { first.fulfill() }
                }
                return received
            }
        }
        defer { tasks.forEach { $0.cancel() } }
        await fulfillment(of: [first], timeout: 15)
        XCTAssertEqual(fixture.activeStreams, 8)
        XCTAssertEqual(fixture.connections, 1, "All chats share one authenticated SSH connection")

        let payload = Data(#"{"approval":"allow_once","feedback":"Keep ✓"}"#.utf8)
        let echoed = try await channel.perform(method: "POST", path: "/control", jsonBody: payload)
        XCTAssertEqual(echoed.status, 200)
        XCTAssertEqual(echoed.body, String(decoding: payload, as: UTF8.self))
        XCTAssertEqual(fixture.activeStreams, 8, "Control calls must work while every stream remains open")
        do {
            let missing = try await channel.stream(method: "GET", path: "/missing-stream", jsonBody: nil)
            for try await _ in missing {}
            XCTFail("The missing run must report its HTTP error")
        } catch {}
        XCTAssertEqual(fixture.activeStreams, 8, "One run's HTTP error must not disconnect other chats")
        tasks[0].cancel()
        try await eventually { fixture.activeStreams == 7 }
        let health: DaemonHealth = try await http.decode("GET", "/healthz")
        XCTAssertTrue(health.ok, "Cancelling one chat must not close the shared tunnel")
        _ = try await channel.perform(method: "POST", path: "/finish", jsonBody: nil)
        for task in tasks.dropFirst() {
            let events = try await task.value
            XCTAssertEqual(events.map(\.text), ["Working 🔧", "Finished ✓"])
        }
        XCTAssertEqual(fixture.shellRequests, 0, "The chat path must not execute curl or other remote commands")
        XCTAssertEqual(fixture.authorizationFailures, 0)
    }

    func testClosedSSHConnectionReopensAndFailedMutationIsNotReplayed() async throws {
        let fixture = try await SSHHTTPFixture.start()
        addTeardownBlock { await fixture.stop() }
        let ssh = fixture.connection()
        defer { ssh.close() }
        let channel = SSHTunnelChannel(ssh: ssh, token: SSHHTTPFixture.token)
        _ = try await channel.perform(method: "GET", path: "/healthz", jsonBody: nil)
        await fixture.disconnectClients()
        try await eventually {
            (try? await channel.perform(method: "GET", path: "/healthz", jsonBody: nil).status) == 200
        }
        XCTAssertEqual(fixture.connections, 2)
        do {
            _ = try await channel.perform(method: "POST", path: "/drop-mutation", jsonBody: Data("{}".utf8))
            XCTFail("A lost response must not be reported as success")
        } catch {}
        XCTAssertEqual(fixture.mutations, 1, "Transport recovery must not duplicate a potentially accepted operation")
        let recovered = try await channel.perform(method: "GET", path: "/healthz", jsonBody: nil)
        XCTAssertEqual(recovered.status, 200)
        XCTAssertEqual(fixture.shellRequests, 0)
    }

    func testPrivateForwardResumesWithoutInterruptingTheSharedSSHStream() async throws {
        let fixture = try await SSHHTTPFixture.start()
        addTeardownBlock { await fixture.stop() }
        let ssh = fixture.connection()
        defer { ssh.close() }
        let http = DaemonHTTP(channel: SSHTunnelChannel(ssh: ssh, token: SSHHTTPFixture.token), agentType: "")
        let stream = Task { for try await _ in try XCTUnwrap(http.stream("/stream/forward-test")) {} }
        defer { stream.cancel() }
        try await eventually { fixture.activeStreams == 1 }
        let suite = "native-forward-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let connection = Connection.ssh(.init(id: "native-fixture", name: "Fixture", type: .ssh,
            host: "127.0.0.1", port: 22, username: "fixture", auth: .agent, createdAt: isoNow()))
        stores.connections.save(connection)
        let network = ComputerNetworkMonitor(observeSystem: false)
        let manager = ConnectionPortForwards(stores: stores, network: network) { connection, port, local in
            ConnectionPortForward(connection: connection, port: port, network: network, stores: stores,
                localPort: local, makeListener: { bound in
                    try await ssh.forwardLocal(host: "127.0.0.1", port: AppConstants.daemonPort, localPort: bound)
                })
        }
        let forward = manager.open(connection: connection, port: AppConstants.daemonPort)
        defer { manager.close(forward) }
        let port = try await forward.ready()
        func readHealth() async throws {
            let url = try XCTUnwrap(forward.url).appendingPathComponent("healthz")
            var request = URLRequest(url: url)
            request.setValue("Bearer \(SSHHTTPFixture.token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(try JSONDecoder().decode(DaemonHealth.self, from: data).ok)
        }
        try await readHealth()
        manager.setActive(false)
        XCTAssertNil(forward.url)
        XCTAssertTrue(ssh.isConnected)
        XCTAssertEqual(fixture.activeStreams, 1)
        manager.setActive(true)
        let resumedPort = try await forward.ready()
        XCTAssertEqual(resumedPort, port)
        try await readHealth()
        XCTAssertEqual(fixture.connections, 1, "Restarting a preview must leave its shared SSH connection intact")
        XCTAssertEqual(fixture.activeStreams, 1, "The active daemon stream must survive the forwarding lifecycle")
    }

    func testNativeKeyChecksRequireTrustedHostAndRejectInvalidKeysWithoutRetrying() async throws {
        let authorized = SSHKey.generate(comment: "authorized")
        let fixture = try await SSHHTTPFixture.start(acceptedKey: authorized.nioPrivateKey.publicKey)
        addTeardownBlock { await fixture.stop() }
        let connection = fixture.connection(auth: .privateKey(authorized.nioPrivateKey),
                                            expectedHostKeys: [fixture.fingerprint, "SHA256:another-key"])
        defer { connection.close() }
        try await connection.authenticate()
        XCTAssertTrue(connection.isConnected)
        XCTAssertEqual(fixture.shellRequests, 0, "Connection tests must not execute commands")

        let wrong = SSHKey.generate(comment: "not-authorized")
        let rejected = fixture.connection(auth: .privateKey(wrong.nioPrivateKey))
        defer { rejected.close() }
        let requests = fixture.keyRequests
        let start = Date()
        do {
            try await rejected.authenticate()
            XCTFail("An unknown key must not authenticate")
        } catch {
            XCTAssertTrue(error is SSHAuthenticationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "A rejected key must not loop until the timeout")
        XCTAssertEqual(fixture.keyRequests - requests, 1)

        let untrusted = fixture.connection(auth: .privateKey(authorized.nioPrivateKey), expectedHostKeys: [])
        defer { untrusted.close() }
        let attempts = fixture.keyRequests
        do {
            try await untrusted.authenticate()
            XCTFail("An empty provider pin set must not enable trust-on-first-use")
        } catch {}
        XCTAssertEqual(fixture.keyRequests, attempts, "Never offer credentials before checking the host identity")
    }

    func testComputerRouteRacingPreservesRejectedKeysAndHostPins() async throws {
        let accepted = SSHKey.generate(comment: "phone")
        let fixture = try await SSHHTTPFixture.start(acceptedKey: accepted.nioPrivateKey.publicKey)
        addTeardownBlock { await fixture.stop() }
        let routes = [ComputerRoute(kind: "ssh", host: "127.0.0.1", port: 1), fixture.route]
        let connected = try await ComputerSSHLink.open(routes: routes, username: "fixture", auth: .privateKey(accepted.nioPrivateKey),
            fingerprint: fixture.fingerprint, port: 8790, token: SSHHTTPFixture.token)
        connected.ssh.close()
        let wrong = SSHKey.generate(comment: "lost-key")
        let attempts = fixture.keyRequests
        do {
            _ = try await ComputerSSHLink.open(routes: routes, username: "fixture", auth: .privateKey(wrong.nioPrivateKey),
                fingerprint: fixture.fingerprint, port: 8790, token: nil, attempts: 3)
            XCTFail("A rejected phone key must not connect")
        } catch {
            XCTAssertEqual(error as? ComputerConnectionError, .notPaired)
        }
        XCTAssertEqual(fixture.keyRequests - attempts, 1, "Repairing credentials must not be treated as a network retry")
        do {
            _ = try await ComputerSSHLink.open(routes: routes, username: "fixture", auth: .privateKey(accepted.nioPrivateKey),
                fingerprint: "SHA256:wrong-host", port: 8790, token: nil, attempts: 3)
            XCTFail("A changed host must not connect")
        } catch {
            XCTAssertEqual(error as? ComputerConnectionError, .identityChanged)
        }
        do {
            _ = try await ComputerSSHLink.open(routes: [fixture.route], username: "fixture", auth: .password("expired-code"),
                fingerprint: fixture.fingerprint, port: 8790, token: nil, attempts: 3)
            XCTFail("An invalid pairing password must not connect")
        } catch {
            XCTAssertEqual(error as? ComputerConnectionError, .codeRejected)
        }
    }

    func testComputerTunnelFailureSurvivesTheNativeSSHBridge() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(UnavailableTunnelFixture()) }
            .bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock {
            try? await server.close().get()
            await withCheckedContinuation { continuation in group.shutdownGracefully { _ in continuation.resume() } }
        }
        do {
            _ = try await ComputerSSHLink.open(routes: [ComputerRoute(kind: "websocket", url: "ws://127.0.0.1:\(server.localAddress!.port!)/ssh")],
                username: "fixture", auth: .password("fixture"), fingerprint: "SHA256:fixture", port: 8790, token: nil)
            XCTFail("An unavailable tunnel must fail")
        } catch {
            XCTAssertEqual(error as? ComputerConnectionError, .tunnelUnavailable)
        }
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native SSH transport did not reach the expected state")
    }
}

/// A real encrypted SSH server with an HTTP/SSE endpoint on its direct-tcpip channels.
/// No host SSH daemon, account, shell commands, or cloud credentials are involved.
final class SSHHTTPFixture {
    static let token = "ssh-test-daemon-token"
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    private let lock = NSLock()
    private var listener: Channel?
    private var clients: [Channel] = []
    private var streams: [ObjectIdentifier: (Channel, () -> Void)] = [:]
    private var connectionCount = 0
    private var shellCount = 0
    private var unauthorizedCount = 0
    private var mutationCount = 0
    private var keyCount = 0
    private var installationCount = 0
    private var commandResult: ((String) -> ExecResult?)?
    var connections: Int { lock.withLock { connectionCount } }
    var activeStreams: Int { lock.withLock { streams.count } }
    var shellRequests: Int { lock.withLock { shellCount } }
    var authorizationFailures: Int { lock.withLock { unauthorizedCount } }
    var mutations: Int { lock.withLock { mutationCount } }
    var keyRequests: Int { lock.withLock { keyCount } }
    var installations: Int { lock.withLock { installationCount } }
    var fingerprint: String { PinnedSSHHostKey.fingerprint(key.publicKey)! }
    var route: ComputerRoute { ComputerRoute(kind: "ssh", host: "127.0.0.1", port: listener!.localAddress!.port!) }

    static func start(acceptedKey: NIOSSHPublicKey? = nil,
                      commandResult: ((String) -> ExecResult?)? = nil) async throws -> SSHHTTPFixture {
        let fixture = SSHHTTPFixture()
        fixture.commandResult = commandResult
        fixture.listener = try await ServerBootstrap(group: fixture.group)
            .childChannelInitializer { parent in
                fixture.lock.withLock { fixture.clients.append(parent); fixture.connectionCount += 1 }
                return parent.pipeline.addHandler(NIOSSHHandler(
                    role: .server(.init(hostKeys: [fixture.key], userAuthDelegate: SSHFixtureAuth(acceptedKey: acceptedKey,
                        onKey: { fixture.lock.withLock { fixture.keyCount += 1 } }))),
                    allocator: parent.allocator,
                    inboundChildChannelInitializer: { child, type in
                        if type == .session {
                            fixture.lock.withLock { fixture.shellCount += 1 }
                            return child.pipeline.addHandler(SSHFixtureExecHandler(fixture: fixture))
                        }
                        guard case .directTCPIP(let destination) = type,
                              destination.targetHost == "127.0.0.1", destination.targetPort == 8790 else {
                            fixture.lock.withLock { fixture.shellCount += 1 }
                            return child.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                        }
                        return child.pipeline.addHandler(SSHFixtureHTTPHandler(fixture: fixture))
                    }))
            }.bind(host: "127.0.0.1", port: 0).get()
        return fixture
    }

    func connection(auth: SSHConnection.Auth = .password("fixture"), expectedHostKeys: Set<String>? = nil) -> SSHConnection {
        SSHConnection(host: "127.0.0.1", port: listener!.localAddress!.port!, username: "fixture",
            auth: auth, expectedHostKey: fingerprint, expectedHostKeys: expectedHostKeys)
    }

    func disconnectClients() async {
        let clients = lock.withLock { self.clients }
        for client in clients { try? await client.close().get() }
    }

    func stop() async {
        try? await listener?.close().get()
        await disconnectClients()
        await withCheckedContinuation { continuation in group.shutdownGracefully { _ in continuation.resume() } }
    }

    func unauthorized() { lock.withLock { unauthorizedCount += 1 } }
    func mutated() { lock.withLock { mutationCount += 1 } }
    func recordCommand(_ command: String) {
        if command.contains("DAEMON_PROGRESS downloading") { lock.withLock { installationCount += 1 } }
    }
    func result(for command: String) -> ExecResult? { commandResult?(command) }
    func hold(_ channel: Channel, finish: @escaping () -> Void) {
        lock.withLock { streams[ObjectIdentifier(channel)] = (channel, finish) }
    }
    func closed(_ channel: Channel) { _ = lock.withLock { streams.removeValue(forKey: ObjectIdentifier(channel)) } }
    func finish() {
        let callbacks = lock.withLock { Array(streams.values) }
        for (channel, callback) in callbacks { channel.eventLoop.execute(callback) }
    }
}

private final class UnavailableTunnelFixture: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var response = context.channel.allocator.buffer(capacity: 128)
        response.writeString("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let channel = context.channel
        channel.writeAndFlush(response).whenComplete { _ in channel.close(promise: nil) }
    }
}

private final class SSHFixtureExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let fixture: SSHHTTPFixture
    init(fixture: SSHHTTPFixture) { self.fixture = fixture }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let request = event as? SSHChannelRequestEvent.ExecRequest else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        let channel = context.channel
        fixture.recordCommand(request.command)
        if let result = fixture.result(for: request.command) {
            send(channel, result.stdout, stderr: false)
            send(channel, result.stderr, stderr: true)
            finish(channel, code: result.exitCode)
        } else if request.command.contains("<<OS:%s>>") {
            send(channel, "<<OS:Darwin>><<ARCH:arm64>><<DIR:/fixture/.mindwire>><<USER:fixture>>", stderr: false)
            finish(channel)
        } else if request.command.contains("DAEMON_OK startup-configured") || request.command.contains("DAEMON_OK background") {
            // Registration is a separate, short exec before the streamed download.
            send(channel, "DAEMON_OK startup-configured\n", stderr: false)
            finish(channel)
        } else {
            send(channel, "DAEMON_PROGRESS downloading\n", stderr: false)
            send(channel, "\r################ 62", stderr: true)
            send(channel, ".5%\r", stderr: true)
            fixture.hold(channel) { [weak self, weak channel] in
                guard let self, let channel else { return }
                self.send(channel, "DAEMON_PROGRESS starting\nDAEMON_OK 0.1.22\n", stderr: false)
                self.finish(channel)
            }
        }
    }

    private func send(_ channel: Channel, _ text: String, stderr: Bool) {
        var buffer = channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        channel.writeAndFlush(SSHChannelData(type: stderr ? .stdErr : .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    private func finish(_ channel: Channel, code: Int? = 0) {
        guard let code else { channel.close(promise: nil); return }
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: code)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fixture.closed(context.channel)
        context.fireChannelInactive()
    }
}

private struct SSHFixtureAuth: NIOSSHServerUserAuthenticationDelegate {
    var acceptedKey: NIOSSHPublicKey? = nil
    var onKey: () -> Void = {}
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.password, .publicKey] }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .publicKey(let key) = request.request {
            onKey()
            responsePromise.succeed(request.username == "fixture" && key.publicKey == acceptedKey ? .success : .failure)
        } else if request.username == "fixture", case .password(let password) = request.request, password.password == "fixture" {
            responsePromise.succeed(.success)
        } else { responsePromise.succeed(.failure) }
    }
}

private final class SSHFixtureHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let fixture: SSHHTTPFixture
    private var buffer = Data()
    private var handled = false
    init(fixture: SSHHTTPFixture) { self.fixture = fixture }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !handled, case .byteBuffer(let bytes) = unwrapInboundIn(data).data else { return }
        buffer.append(contentsOf: bytes.readableBytesView)
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let header = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = Data(buffer[split.upperBound...])
        guard body.count >= length else { return }
        handled = true
        guard lines.contains(where: { $0.lowercased() == "authorization: bearer \(SSHHTTPFixture.token)" }) else {
            fixture.unauthorized(); respond(context.channel, status: 401, body: Data()); return
        }
        let path = String(lines[0].split(separator: " ")[1].split(separator: "?")[0])
        if path.hasPrefix("/stream/") {
            send(context.channel, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
            event(context.channel, text: "Working 🔧")
            fixture.hold(context.channel) { [weak self, weak channel = context.channel] in
                guard let self, let channel else { return }
                self.event(channel, text: "Finished ✓")
                self.send(channel, "0\r\n\r\n", close: true)
            }
        } else if path == "/missing-stream" {
            respond(context.channel, status: 404, body: Data())
        } else if path == "/finish" {
            fixture.finish(); respond(context.channel, status: 204, body: Data())
        } else if path == "/drop-mutation" {
            fixture.mutated(); context.close(promise: nil)
        } else if path == "/control" {
            respond(context.channel, status: 200, body: body)
        } else {
            respond(context.channel, status: 200, body: Data(#"{"ok":true,"version":"1.0.0"}"#.utf8))
        }
    }

    private func respond(_ channel: Channel, status: Int, body: Data) {
        send(channel, "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n" + String(decoding: body, as: UTF8.self), close: true)
    }

    private func event(_ channel: Channel, text: String) {
        let payload = "data: {\"type\":\"text\",\"text\":\"\(text)\"}\r\n\r\n"
        // Split transport writes, including inside the UTF-8 event, to exercise native framing.
        let data = Data((String(payload.utf8.count, radix: 16) + "\r\n" + payload + "\r\n").utf8)
        for byte in data {
            var buffer = channel.allocator.buffer(capacity: 1); buffer.writeInteger(byte)
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        }
    }

    private func send(_ channel: Channel, _ text: String, close: Bool = false) {
        var bytes = channel.allocator.buffer(capacity: text.utf8.count); bytes.writeString(text)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bytes))).whenComplete { _ in
            if close { channel.close(promise: nil) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fixture.closed(context.channel); context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
