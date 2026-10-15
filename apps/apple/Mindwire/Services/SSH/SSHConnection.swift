import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A single authenticated SSH connection to a host, serving both one-shot `exec` (control) and
/// an interactive shell (terminal). Built on swift-nio-ssh, modeled on Apple's `NIOSSHClient`
/// sample. One connection is reused for a server's exec surface and its terminal.
final class SSHConnection {
    enum Auth {
        case password(String)
        case privateKey(NIOSSHPrivateKey)
        case unavailable(String)
    }

    /// Handles for driving an open interactive shell.
    struct ShellHandle {
        let send: (Data) -> Void
        let resize: (Int, Int) -> Void
    }

    let host: String
    let port: Int
    let username: String
    private let auth: Auth
    private let expectedHostKeys: Set<String>?
    private let websocketURL: URL?
    private let connectTimeoutSeconds: Int64
    private var carrier: WebSocketSSHBridge?
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    /// Guards `channel`/`connectTask`/`didShutdown` — this is a plain class touched concurrently.
    private let lock = NSLock()
    private var channel: Channel?
    private struct ConnectAttempt {
        let id = UUID()
        let task: Task<Channel, Error>
    }
    /// In-flight connect, shared so concurrent callers single-flight one TCP+SSH handshake.
    private var connectTask: ConnectAttempt?
    private var didShutdown = false

    init(host: String, port: Int, username: String, auth: Auth, expectedHostKey: String? = nil,
         websocketURL: URL? = nil, connectTimeoutSeconds: Int64 = 15, expectedHostKeys: Set<String>? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.expectedHostKeys = expectedHostKeys ?? expectedHostKey.map { [$0] }
        self.websocketURL = websocketURL
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    deinit { close() }

    func authenticate() async throws { try await ensureConnected() }
    var isConnected: Bool { lock.withLock { channel?.isActive == true && !didShutdown } }

    /// Build a connection from a saved server, reading the secret/key from the Keychain.
    static func make(for connection: RemoteHostConnection) -> SSHConnection {
        let auth: Auth
        switch connection.auth {
        case .password(let ref):
            auth = Keychain.get(ref).map(Auth.password)
                ?? .unavailable("This server needs its password. Open Edit Connection to add it, or restore its credential with iCloud Sync.")
        case .key(let ref):
            auth = Keychain.get(ref).map { authentication(method: .key, secret: $0) }
                ?? .unavailable("This server needs its SSH key. Open Edit Connection to add it, or restore its credential with iCloud Sync.")
        case .agent:
            auth = authentication(method: .agent, secret: "")
        }
        return SSHConnection(host: connection.host, port: connection.port, username: connection.username, auth: auth)
    }

    static func authentication(method: ServerAuthMethod, secret: String) -> Auth {
        switch method {
        case .password: return .password(secret)
        case .key:
            return SSHKey.privateKey(from: secret).map(Auth.privateKey)
                ?? .unavailable("Use an unencrypted Ed25519 private key for this SSH connection.")
        case .agent: return .unavailable("SSH agent authentication isn't available on iPhone. Use a password or an Ed25519 key.")
        }
    }

    /// Single-flight connect: concurrent exec/startShell/status calls share one handshake instead
    /// of each opening (and leaking) its own channel.
    private func ensureConnected() async throws {
        let attempt: ConnectAttempt? = try lock.withLock {
            guard !didShutdown else { throw SSHError.notConnected }
            if channel?.isActive == true { return nil }
            channel = nil
            if let existing = connectTask { return existing }
            let attempt = ConnectAttempt(task: Task { [weak self] in
                guard let self else { throw SSHError.notConnected }
                return try await self.openConnection()
            })
            connectTask = attempt
            return attempt
        }
        guard let attempt else { return }
        do {
            let ch = try await attempt.task.value
            try lock.withLock {
                guard !didShutdown, ch.isActive else { throw SSHError.notConnected }
                // Late completion from an old waiter must not clear a newer reconnect.
                guard connectTask?.id == attempt.id || channel === ch else { throw SSHError.notConnected }
                channel = ch; connectTask = nil
            }
            try Task.checkCancellation()
        } catch {
            lock.withLock { if connectTask?.id == attempt.id { connectTask = nil } }
            throw error
        }
    }

    private func openConnection() async throws -> Channel {
        try Task.checkCancellation()
        let authDelegate: NIOSSHClientUserAuthenticationDelegate
        switch auth {
        case .password(let password):
            authDelegate = PasswordAuthDelegate(username: username, password: password)
        case .privateKey(let key):
            authDelegate = KeyAuthDelegate(username: username, privateKey: key)
        case .unavailable(let reason):
            throw BackendError.message(reason)
        }
        let hostKeyDelegate: NIOSSHClientServerAuthenticationDelegate = expectedHostKeys.map { PinnedSSHHostKey($0) }
            ?? StoredSSHHostKey(host: host, port: port)
        var address = host, targetPort = port
        if let websocketURL {
            let bridge = WebSocketSSHBridge(url: websocketURL)
            let old = try lock.withLock {
                guard !didShutdown else { throw SSHError.notConnected }
                let old = carrier; carrier = bridge; return old
            }
            old?.close()
            targetPort = try await bridge.open()
            address = "127.0.0.1"
        }
        let ready = group.next().makePromise(of: Void.self)
        let handshake = SSHReadyHandler(promise: ready)
        let pendingTCP = SSHConnectCancellation()
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(connectTimeoutSeconds))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                guard pendingTCP.register(channel) else { return channel.eventLoop.makeFailedFuture(CancellationError()) }
                return channel.pipeline.addHandlers([
                    NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: hostKeyDelegate)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    ), handshake
                ])
            }
        let connected: Channel
        do {
            connected = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await bootstrap.connect(host: address, port: targetPort).get()
            } onCancel: { pendingTCP.cancel() }
        } catch {
            ready.futureResult.eventLoop.execute { handshake.fail(error) }
            let bridge = lock.withLock { carrier }
            let cause = bridge?.failure ?? error
            bridge?.close(); throw cause
        }
        // A route can be cancelled before it becomes active. In that case NIO does
        // not promise channelInactive, but closeFuture always resolves the waiter.
        connected.closeFuture.whenComplete { _ in handshake.fail(SSHError.notConnected) }
        let timeout = connected.eventLoop.scheduleTask(in: .seconds(connectTimeoutSeconds)) {
            handshake.fail(SSHError.timedOut)
            connected.close(promise: nil)
        }
        defer { timeout.cancel() }
        do {
            try await withTaskCancellationHandler { try await ready.futureResult.get() }
                onCancel: { connected.close(promise: nil) }
            return connected
        } catch {
            let bridge = lock.withLock { carrier }
            let cause = bridge?.failure ?? error
            connected.close(promise: nil); bridge?.close(); throw cause
        }
    }

    /// Share the authenticated transport with a native, loopback-only protocol client.
    func forwardLocal(host: String, port: Int, localPort: Int = 0) async throws -> SSHLocalForwarder {
        try await ensureConnected()
        let parent = lock.withLock { channel }
        guard let parent else { throw SSHError.notConnected }
        let forward = try await SSHLocalForwarder.open(over: parent, host: host, port: port, localPort: localPort)
        do { try Task.checkCancellation() }
        catch { forward.close(); throw error }
        return forward
    }

    /// Run one command, collecting stdout/stderr by default. A callback streams the output
    /// instead, so long-running downloads do not retain every progress line in memory.
    func exec(_ cmd: [String], timeoutSeconds: Int64 = 300,
              onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> ExecResult {
        try await ensureConnected()
        let channel = lock.withLock { self.channel }
        guard let channel else { throw SSHError.notConnected }

        let resultPromise = channel.eventLoop.makePromise(of: ExecResult.self)
        let command = Self.commandString(cmd)
        // Open the child channel ON the event loop — NIOSSHHandler.createChannel is documented as
        // not thread-safe and must run on the channel's loop.
        let childFuture = channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh -> EventLoopFuture<Channel> in
            let childPromise = channel.eventLoop.makePromise(of: Channel.self)
            ssh.createChannel(childPromise) { child, type in
                guard type == .session else { return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType) }
                return child.pipeline.addHandler(ExecCollector(command: command, promise: resultPromise, onOutput: onOutput))
            }
            return childPromise.futureResult
        }
        childFuture.whenFailure { resultPromise.fail($0) }

        // Wall-clock bound so a wedged remote command can't hang the await forever; close the
        // child to release the session. Promise fulfilment is idempotent — first to fire wins.
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(timeoutSeconds)) {
            childFuture.whenSuccess { $0.close(promise: nil) }
            resultPromise.fail(SSHError.timedOut)
        }
        resultPromise.futureResult.whenComplete { _ in timeout.cancel() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await resultPromise.futureResult.get()
        } onCancel: {
            childFuture.whenSuccess { $0.close(promise: nil) }
        }
    }

    /// Stream over an ordinary exec channel, without a PTY or buffering until process exit.
    func execStream(_ cmd: [String]) -> AsyncThrowingStream<ExecEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await exec(cmd, onOutput: { continuation.yield(.output($0)) })
                    continuation.yield(.exit(result.exitCode))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// SSH's exec request carries one shell command string, not an argv. Quote every argument so
    /// structured calls such as `["bash", "-lc", script]` survive as exactly three remote argv
    /// values; joining with spaces truncated scripts at their first word and broke deployment,
    /// files, Git, and resource probes.
    static func commandString(_ argv: [String]) -> String {
        argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }

    /// Open a PTY with a shell or a specific command. Container terminals use an exec
    /// request so a failed `docker exec` cannot leave the user in a host shell.
    func startShell(cols: Int, rows: Int, command: [String]? = nil,
                    onOutput: @escaping (Data) -> Void) async throws -> ShellHandle {
        try await ensureConnected()
        let channel = lock.withLock { self.channel }
        guard let channel else { throw SSHError.notConnected }

        // Open the child channel ON the event loop — NIOSSHHandler.createChannel is not thread-safe.
        let childFuture = channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh -> EventLoopFuture<Channel> in
            let childPromise = channel.eventLoop.makePromise(of: Channel.self)
            ssh.createChannel(childPromise) { child, type in
                guard type == .session else { return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType) }
                let command = command.map { Self.commandString(["bash", "-lc", "exec " + Self.commandString($0)]) }
                return child.pipeline.addHandler(ShellDataHandler(cols: cols, rows: rows, command: command, onData: onOutput))
            }
            return childPromise.futureResult
        }
        let child = try await childFuture.get()
        return ShellHandle(
            send: { data in
                var buffer = child.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                child.eventLoop.execute { _ = child.writeAndFlush(buffer) }
            },
            resize: { cols, rows in
                let event = SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: cols, terminalRowHeight: rows,
                    terminalPixelWidth: 0, terminalPixelHeight: 0
                )
                child.eventLoop.execute { _ = child.triggerUserOutboundEvent(event) }
            }
        )
    }

    func close() {
        let resources: (Channel?, Task<Channel, Error>?, WebSocketSSHBridge?)? = lock.withLock {
            guard !didShutdown else { return nil }
            didShutdown = true
            let resources = (channel, connectTask?.task, carrier)
            channel = nil; connectTask = nil; carrier = nil
            return resources
        }
        guard let (channel, connecting, carrier) = resources else { return }
        connecting?.cancel(); carrier?.close()
        let group = self.group
        // Let cancellation finish any pending handshake before shutting its loop
        // down. Otherwise a losing route can schedule cleanup on a dead event loop.
        Task.detached {
            if let pending = try? await connecting?.value { try? await pending.close().get() }
            if let channel { try? await channel.close().get() }
            group.shutdownGracefully { _ in }
        }
    }
}

enum SSHError: Error { case notConnected, invalidChannelType, timedOut, channelClosedWithoutExit }

/// Cancel a losing route during TCP connection too, not only after SSH starts.
/// Otherwise the selected internet route waits for an unreachable LAN timeout.
private final class SSHConnectCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var cancelled = false

    func register(_ channel: Channel) -> Bool {
        let accepted = lock.withLock {
            guard !cancelled else { return false }
            self.channel = channel
            return true
        }
        if !accepted { channel.close(promise: nil) }
        return accepted
    }

    func cancel() {
        let pending = lock.withLock { cancelled = true; return channel }
        pending?.close(promise: nil)
    }
}

// MARK: - Auth delegates

/// Legacy manual SSH connections remember the first host key. QR pairing always
/// supplies an out-of-band pin and never uses this fallback.
final class StoredSSHHostKey: NIOSSHClientServerAuthenticationDelegate {
    private let key: String
    private static let queue = DispatchQueue(label: "mindwire.ssh.hostkeys")
    init(host: String, port: Int) { key = "ssh.host." + Data("\(host.lowercased()):\(port)".utf8).base64EncodedString() }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        Self.queue.sync {
            guard let fingerprint = PinnedSSHHostKey.fingerprint(hostKey) else {
                validationCompletePromise.fail(SSHError.notConnected); return
            }
            if let saved = Keychain.get(key) {
                guard saved == fingerprint else {
                    validationCompletePromise.fail(BackendError.message("This server's SSH identity changed. Verify its host key before reconnecting.")); return
                }
            } else if !Keychain.set(fingerprint, for: key) {
                validationCompletePromise.fail(ComputerConnectionError.keyStorage); return
            }
            validationCompletePromise.succeed(())
        }
    }
}

/// No workspace request starts before authentication succeeds. Host-key failures
/// and rejected device keys complete the connect immediately instead of hanging.
private final class SSHReadyHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<Void>
    private var finished = false
    init(promise: EventLoopPromise<Void>) { self.promise = promise }
    func fail(_ error: Error) { guard !finished else { return }; finished = true; promise.fail(error) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !finished { finished = true; promise.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { fail(SSHError.notConnected); context.fireChannelInactive() }
    func handlerRemoved(context: ChannelHandlerContext) { fail(SSHError.notConnected) }
}

final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var offered = false
    init(username: String, password: String) { self.username = username; self.password = password }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password), !offered else {
            nextChallengePromise.fail(SSHAuthenticationError.passwordRejected); return
        }
        offered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: password)))
        )
    }
}

final class KeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var offered = false
    init(username: String, privateKey: NIOSSHPrivateKey) { self.username = username; self.privateKey = privateKey }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), !offered else {
            nextChallengePromise.fail(SSHAuthenticationError.keyRejected)
            return
        }
        offered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: privateKey)))
        )
    }
}

enum SSHAuthenticationError: LocalizedError {
    case keyRejected, passwordRejected
    var errorDescription: String? {
        switch self {
        case .keyRejected: "The server did not accept this SSH key."
        case .passwordRejected: "The server did not accept this password."
        }
    }
}

enum SSHIdentityError: LocalizedError {
    case changed
    var errorDescription: String? { "The SSH identity doesn't match this connection. Verify the computer before reconnecting." }
}

// MARK: - exec channel (collect stdout/stderr/exit)

private final class ExecCollector: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let promise: EventLoopPromise<ExecResult>
    private let onOutput: (@Sendable (Data) -> Void)?
    private var stdout = Data()
    private var stderr = Data()
    private var exitCode: Int?
    private var exitSignaled = false
    private var finished = false

    init(command: String, promise: EventLoopPromise<ExecResult>, onOutput: (@Sendable (Data) -> Void)? = nil) {
        self.command = command
        self.promise = promise
        self.onOutput = onOutput
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        let bytes = Data(buffer.readableBytesView)
        if let onOutput { onOutput(bytes) }
        else if channelData.type == .stdErr { stderr.append(bytes) }
        else { stdout.append(bytes) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitCode = status.exitStatus
        } else if event is SSHChannelRequestEvent.ExitSignal {
            exitSignaled = true // process died via signal (e.g. OOM-killed) — not a clean exit
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish() // safety net: an abnormal teardown may skip channelInactive
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        // Only a clean exit-status is success. A channel that closed without one (dropped mid-run)
        // or a signal-killed process must surface as a failure so callers don't read a broken
        // command as success.
        guard let exitCode, !exitSignaled else {
            promise.fail(SSHError.channelClosedWithoutExit)
            return
        }
        promise.succeed(ExecResult(
            exitCode: exitCode,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        ))
    }
}

// MARK: - shell channel (PTY + interactive bytes)

private final class ShellDataHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let cols: Int
    private let rows: Int
    private let command: String?
    private let onData: (Data) -> Void

    init(cols: Int, rows: Int, command: String?, onData: @escaping (Data) -> Void) {
        self.cols = cols
        self.rows = rows
        self.command = command
        self.onData = onData
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: "xterm-256color",
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        if let command {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false), promise: nil)
        } else {
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false), promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        onData(Data(buffer.readableBytesView))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}
