import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

/// Loopback-only forwarding for native protocols such as HTTP/SSE and RFB. Both halves use
/// the SSH event loop, with reads suspended while the peer is backpressured.
final class SSHLocalForwarder {
    private let lock = NSLock()
    private var channels: [Channel] = []
    private var closed = false
    private var listener: Channel?
    private let connectionLimit: Int
    private(set) var port = 0

    private init(connectionLimit: Int) { self.connectionLimit = max(1, connectionLimit) }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && listener?.isActive == true
    }

    static func open(over parent: Channel, host: String, port: Int, connectionLimit: Int = 16, localPort: Int = 0) async throws -> SSHLocalForwarder {
        let forward = SSHLocalForwarder(connectionLimit: connectionLimit)
        // A dead SSH connection must close its listener too, so the next API call
        // opens a new tunnel instead of repeatedly connecting to a dead forwarder.
        parent.closeFuture.whenComplete { [weak forward] _ in forward?.close() }
        let listener = try await ServerBootstrap(group: parent.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { local in
                guard forward.track(local) else { return local.eventLoop.makeFailedFuture(SSHError.notConnected) }
                return parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                    let promise = parent.eventLoop.makePromise(of: Channel.self)
                    let type = SSHChannelType.directTCPIP(.init(targetHost: host, targetPort: port,
                        originatorAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0)))
                    ssh.createChannel(promise, channelType: type) { remote, type in
                        guard case .directTCPIP = type, forward.track(remote) else {
                            return parent.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                        }
                        return remote.pipeline.addHandler(ForwardSSHBytes(peer: local))
                    }
                    let timeout = parent.eventLoop.scheduleTask(in: .seconds(15)) { local.close(promise: nil) }
                    return promise.futureResult.flatMap { remote in
                        timeout.cancel()
                        // An accepted socket is not active until this initializer finishes.
                        guard forward.contains(local) else { remote.close(promise: nil); return local.eventLoop.makeFailedFuture(SSHError.timedOut) }
                        return local.pipeline.addHandler(ForwardLocalBytes(peer: remote)).flatMap {
                            local.setOption(ChannelOptions.autoRead, value: true)
                        }
                    }.flatMapError { error in
                        timeout.cancel(); local.close(promise: nil)
                        return local.eventLoop.makeFailedFuture(error)
                    }
                }
            }.bind(host: "127.0.0.1", port: localPort).get()
        guard forward.track(listener), let port = listener.localAddress?.port else {
            forward.close(); throw SSHError.notConnected
        }
        forward.lock.lock(); forward.listener = listener; forward.lock.unlock()
        forward.port = port
        guard parent.isActive, forward.isActive else { forward.close(); throw SSHError.notConnected }
        return forward
    }

    private func track(_ channel: Channel) -> Bool {
        lock.lock()
        guard !closed else { lock.unlock(); channel.close(promise: nil); return false }
        // Each forwarded connection has a local and an SSH child channel, plus one listener.
        // Concurrent chat streams must leave room for approval, stop and health requests.
        guard channels.count < 1 + connectionLimit * 2 else { lock.unlock(); channel.close(promise: nil); return false }
        channels.append(channel); lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.channels.removeAll { $0 === channel }; self.lock.unlock()
        }
        return true
    }

    private func contains(_ channel: Channel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && channels.contains { $0 === channel }
    }

    func close() {
        lock.lock(); closed = true; let old = channels; channels = []; listener = nil; lock.unlock()
        for channel in old { channel.close(promise: nil) }
    }
    deinit { close() }
}

private final class ForwardLocalBytes: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let peer: Channel
    init(peer: Channel) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(unwrapInboundIn(data))), promise: nil)
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let resume = context.channel.isWritable
        peer.setOption(ChannelOptions.autoRead, value: resume).whenSuccess {
            // NIOSSH changes autoRead without starting a new read. Explicitly
            // resume buffered frames after the local socket drains; otherwise
            // a large desktop frame can stall permanently under backpressure.
            if resume { self.peer.read() }
        }
        context.fireChannelWritabilityChanged()
    }
    func channelInactive(context: ChannelHandlerContext) { peer.close(promise: nil); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { peer.close(promise: nil); context.close(promise: nil) }
}

private final class ForwardSSHBytes: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let peer: Channel
    init(peer: Channel) { self.peer = peer }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let buffer) = unwrapInboundIn(data).data else { return }
        peer.writeAndFlush(buffer, promise: nil)
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        _ = peer.setOption(ChannelOptions.autoRead, value: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }
    func channelInactive(context: ChannelHandlerContext) { peer.close(promise: nil); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { peer.close(promise: nil); context.close(promise: nil) }
}

final class PinnedSSHHostKey: NIOSSHClientServerAuthenticationDelegate {
    private let fingerprints: Set<String>
    init(_ fingerprint: String) { self.fingerprints = [fingerprint] }
    init(_ fingerprints: Set<String>) { self.fingerprints = fingerprints }
    static func fingerprint(_ key: NIOSSHPublicKey) -> String? {
        let fields = String(openSSHPublicKey: key).split(separator: " ")
        guard fields.count >= 2, let raw = Data(base64Encoded: String(fields[1])) else { return nil }
        return "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if let value = Self.fingerprint(hostKey), fingerprints.contains(value) { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(SSHIdentityError.changed) }
    }
}
