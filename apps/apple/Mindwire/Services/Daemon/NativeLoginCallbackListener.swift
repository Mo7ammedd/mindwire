import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import Darwin

/// A bounded, loopback-only receiver for one native sign-in. It accepts only GET
/// on the declared callback path and returns its response over the daemon's
/// authenticated auth/step API. No native HTML, redirects or tokens are proxied.
final class NativeLoginCallbackListener: @unchecked Sendable {
    private let callback: URL
    private let deliver: @MainActor @Sendable (URL) async throws -> Void
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channels: [Channel] = []
    private var closed = false

    init(callback: URL, deliver: @escaping @MainActor @Sendable (URL) async throws -> Void) {
        self.callback = callback; self.deliver = deliver
    }

    func open() async throws {
        guard let port = callback.port else { throw BackendError.message("Invalid sign-in callback.") }
        do {
            let listener = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [self] channel in
                    guard track(channel) else { return channel.eventLoop.makeFailedFuture(CancellationError()) }
                    return channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMap {
                        channel.pipeline.addHandler(LoginCallbackHTTPHandler(callback: self.callback, deliver: self.deliver))
                    }
                }
                .bind(host: callback.host == "[::1]" || callback.host == "::1" ? "::1" : "127.0.0.1", port: port).get()
            guard track(listener) else { listener.close(promise: nil); throw CancellationError() }
            try Task.checkCancellation()
        } catch {
            close()
            if let failure = error as? IOError, failure.errnoCode == EADDRINUSE {
                throw BackendError.message("Another sign-in is using this port. Finish it, then try again.")
            }
            throw error
        }
    }

    private func track(_ channel: Channel) -> Bool {
        lock.lock()
        guard !closed, channels.count < 9 else { lock.unlock(); channel.close(promise: nil); return false }
        channels.append(channel); lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.channels.removeAll { $0 === channel }; self.lock.unlock()
        }
        return true
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let channels = self.channels; self.channels = []
        lock.unlock()
        for channel in channels { channel.close(promise: nil) }
        group.shutdownGracefully(queue: .global()) { _ in }
    }

    deinit { close() }
}

private final class LoginCallbackHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    private let callback: URL
    private let deliver: @MainActor @Sendable (URL) async throws -> Void
    private var destination: URL?
    private var handling = false
    private var task: Task<Void, Never>?
    private var deadline: Scheduled<Void>?

    init(callback: URL, deliver: @escaping @MainActor @Sendable (URL) async throws -> Void) {
        self.callback = callback; self.deliver = deliver
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = context.eventLoop.scheduleTask(in: .seconds(45)) { channel.close(promise: nil) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !handling else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard destination == nil, head.method == .GET, head.uri.utf8.count <= 8192,
                  head.uri.hasPrefix("/"), !head.uri.hasPrefix("//"),
                  let path = URLComponents(string: head.uri), path.scheme == nil, path.host == nil, path.fragment == nil,
                  var target = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  path.percentEncodedPath == target.percentEncodedPath else {
                reject(context.channel); return
            }
            target.percentEncodedQuery = path.percentEncodedQuery
            destination = target.url
        case .body(let bytes):
            if bytes.readableBytes > 0 { reject(context.channel) }
        case .end:
            guard let destination else { reject(context.channel); return }
            handling = true
            let channel = context.channel, deliver = deliver
            task = Task {
                let status: HTTPResponseStatus
                let message: String
                do {
                    try await deliver(destination)
                    status = .ok; message = "Completing sign-in. You can return to Mindwire."
                } catch {
                    status = .serviceUnavailable; message = "Sign-in could not finish. Return to Mindwire and try again."
                }
                channel.eventLoop.execute { Self.respond(channel, status: status, message: message) }
            }
        }
    }

    private func reject(_ channel: Channel) {
        handling = true
        Self.respond(channel, status: .badRequest, message: "This sign-in link is invalid. Return to Mindwire and try again.")
    }

    private static func respond(_ channel: Channel, status: HTTPResponseStatus, message: String) {
        guard channel.isActive else { return }
        var buffer = channel.allocator.buffer(capacity: 256)
        buffer.writeString("<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><title>Mindwire</title><p>\(message)</p>")
        let headers = HTTPHeaders([("Content-Type", "text/html; charset=utf-8"), ("Content-Length", String(buffer.readableBytes)),
            ("Connection", "close"), ("Cache-Control", "no-store"), ("Referrer-Policy", "no-referrer"),
            ("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")])
        channel.write(NIOAny(HTTPServerResponsePart.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil)
        channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in channel.close(promise: nil) }
    }

    func channelInactive(context: ChannelHandlerContext) { task?.cancel(); deadline?.cancel(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
