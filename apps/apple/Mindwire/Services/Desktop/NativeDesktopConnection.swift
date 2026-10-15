import Foundation
import CoreGraphics
import RoyalVNCKit

protocol DesktopViewing: AnyObject {
    var onFrame: ((DesktopDisplayFrame) -> Void)? { get set }
    var onState: ((Bool, String?) -> Void)? { get set }
    var onCursor: ((DesktopCursorShape, TimeInterval) -> Void)? { get set }
    func connect(port: Int, settings: DesktopStreamSettings, debugLogging: Bool)
    func disconnect()
    func setFrameRate(_ value: Int)
    func requestFreshFrame()
}

/// RoyalVNCKit handles RFB negotiation and compressed frame decoding. Display
/// frames are immutable, bounded copies; slow UI rendering drops obsolete frames.
final class NativeDesktopConnection: NSObject, VNCConnectionDelegate, DesktopViewing {
    var onFrame: ((DesktopDisplayFrame) -> Void)? {
        get { frames.onFrame }
        set { frames.onFrame = newValue }
    }
    var onState: ((Bool, String?) -> Void)?
    var onCursor: ((DesktopCursorShape, TimeInterval) -> Void)?
    private let frames = DesktopFrameDelivery<DesktopDisplayFrame>()
    private var connection: VNCConnection?
    private var bridge: DesktopStreamBridge?
    private var connectTask: Task<Void, Never>?
    private var quality = DesktopStreamQuality.balanced
    private var frameRate = 30
    private let displayLock = NSLock()
    private var latestFramebuffer: VNCFramebuffer?
    private var latestCursor: DesktopCursorShape?

    func connect(port: Int, settings: DesktopStreamSettings = .init(), debugLogging: Bool = false) {
        guard connectTask == nil, connection == nil, !frames.isClosed else { return }
        quality = settings.quality
        frameRate = settings.frameRate
        frames.setFrameRate(Double(settings.frameRate))
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (bridge, localPort) = try await DesktopStreamBridge.open(port: port, settings: settings)
                guard !Task.isCancelled, !self.frames.isClosed else { bridge.close(); return }
                self.bridge = bridge
                bridge.onFrameCompleted = { [weak self] requestedAt in self?.completedFrame(requestedAt: requestedAt) }
                bridge.setFrameRate(self.frameRate)
                let configuration = VNCConnection.Settings(isDebugLoggingEnabled: debugLogging, hostname: "127.0.0.1",
                    port: UInt16(localPort), isShared: true, isScalingEnabled: false, useDisplayLink: false,
                    inputMode: .none, isClipboardRedirectionEnabled: false, colorDepth: settings.quality.colorDepth,
                    frameEncodings: .default)
                let logger: VNCLogger = debugLogging ? VNCPrintLogger() : VNCOSLogLogger()
                let client = VNCConnection(settings: configuration, logger: logger, framebufferAllocator: DesktopFrameAllocator(), context: nil)
                self.connection = client
                client.delegate = self
                client.connect()
            } catch {
                if !self.frames.isClosed { self.onState?(false, "The desktop stream could not connect. Try again.") }
            }
        }
    }

    func setFrameRate(_ value: Int) {
        frameRate = DesktopStreamSettings(framesPerSecond: value).frameRate
        bridge?.setFrameRate(frameRate)
        frames.setFrameRate(Double(frameRate))
    }

    func disconnect() {
        frames.close()
        connectTask?.cancel(); connectTask = nil
        connection?.delegate = nil
        connection?.disconnect()
        connection = nil
        bridge?.close(); bridge = nil
        displayLock.withLock { latestFramebuffer = nil; latestCursor = nil }
    }

    func requestFreshFrame() { bridge?.requestFreshFrame() }

    private func update(_ framebuffer: VNCFramebuffer) {
        // RoyalVNCKit reports each dirty region (including individual tiles) at
        // the end of an update. Coalesce BEFORE copying: a Retina frame can be
        // tens of MiB, even when only a tiny part of it changed.
        displayLock.withLock { latestFramebuffer = framebuffer }
    }

    private func completedFrame(requestedAt: TimeInterval) {
        let (framebuffer, cursor) = displayLock.withLock { (latestFramebuffer, latestCursor) }
        let quality = self.quality
        if let framebuffer {
            frames.submit {
                guard var frame = Self.snapshot(framebuffer, quality: quality) else { return nil }
                frame.requestedAt = requestedAt
                return frame
            }
        }
        if let cursor {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.frames.isClosed else { return }
                self.onCursor?(cursor, requestedAt)
            }
        }
    }

    private static func snapshot(_ framebuffer: VNCFramebuffer, quality: DesktopStreamQuality) -> DesktopDisplayFrame? {
        let width = Int(framebuffer.size.width), height = Int(framebuffer.size.height)
        guard width > 0, height > 0, width * height <= 16 * 1024 * 1024,
              framebuffer.surfaceByteCount == width * height * 4 else { return nil }
        let sourceSize = CGSize(width: width, height: height)
        let size = quality.imageSize(for: sourceSize)
        let format = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
        framebuffer.allocator.lockReadOnly()
        defer { framebuffer.allocator.unlockReadOnly() }
        if size == sourceSize {
            let bytes = Data(bytes: framebuffer.surfaceAddress, count: framebuffer.surfaceByteCount)
            guard let provider = CGDataProvider(data: bytes as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format,
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            return DesktopDisplayFrame(image: image, sourceSize: sourceSize)
        }
        // Read the decoder's buffer only while locked. A scaled snapshot draws
        // straight into its smaller allocation instead of first copying Retina.
        guard let provider = CGDataProvider(dataInfo: nil, data: framebuffer.surfaceAddress,
            size: framebuffer.surfaceByteCount, releaseData: { _, _, _ in }),
              let source = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: format, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(origin: .zero, size: size))
        guard let image = context.makeImage() else { return nil }
        return DesktopDisplayFrame(image: image, sourceSize: sourceSize)
    }

    func connection(_ connection: VNCConnection, stateDidChange state: VNCConnection.ConnectionState) {
        if connection.settings.isDebugLoggingEnabled, let error = state.error { connection.logger.logError(String(describing: error)) }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.frames.isClosed else { return }
            if state.status == .connected { self.onState?(true, nil) }
            if state.status == .disconnected {
                self.onState?(false, state.error == nil ? nil : "The desktop connection ended. Reconnect to continue.")
            }
        }
    }
    func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) { completion(nil) }
    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {}
    // Wait for pixels after a resize; the newly allocated framebuffer is blank.
    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}
    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) { update(framebuffer) }
    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        guard !cursor.isEmpty, cursor.size.width <= 256, cursor.size.height <= 256,
              let image = cursor.cgImage else { return }
        displayLock.withLock { latestCursor = DesktopCursorShape(image: image, hotspot: cursor.cgHotspot) }
    }
    deinit { connectTask?.cancel(); connection?.disconnect(); bridge?.close() }
}

/// At most one immutable frame waits for the main thread. Decoding keeps going
/// while newer regions replace the pending snapshot, rather than queuing full
/// screen copies. There is no timer or work when the desktop is idle.
final class DesktopFrameDelivery<Frame> {
    var onFrame: ((Frame) -> Void)? // Set before connecting; invoked on main.
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var interval: TimeInterval
    private var pending: (() -> Frame?)?
    private var scheduled = false
    private var closed = false
    private var nextFrameAt = DispatchTime.now()

    init(queue: DispatchQueue = DispatchQueue(label: "mindwire.desktop.frames", qos: .userInteractive),
         framesPerSecond: Double = 60) {
        self.queue = queue
        interval = 1 / max(1, framesPerSecond)
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func setFrameRate(_ framesPerSecond: Double) {
        lock.lock()
        interval = 1 / min(60, max(1, framesPerSecond.isFinite ? framesPerSecond : 30))
        lock.unlock()
    }

    func submit(_ snapshot: @escaping () -> Frame?) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        pending = snapshot
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        let deadline = nextFrameAt
        lock.unlock()
        schedule(at: deadline)
    }

    func close() {
        lock.lock(); closed = true; pending = nil; lock.unlock()
    }

    private func schedule(at deadline: DispatchTime) {
        queue.asyncAfter(deadline: deadline) { [weak self] in self?.render() }
    }

    private func render() {
        let startedAt = DispatchTime.now()
        lock.lock()
        let snapshot = closed ? nil : pending
        pending = nil
        lock.unlock()
        let image = snapshot?()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.isClosed, let image { self.onFrame?(image) }
            self.lock.lock()
            // Count rendering time toward the limit instead of adding a second
            // frame interval after a slow copy or a busy main thread.
            self.nextFrameAt = startedAt + self.interval
            let more = !self.closed && self.pending != nil
            self.scheduled = more
            let deadline = self.nextFrameAt
            self.lock.unlock()
            if more { self.schedule(at: deadline) }
        }
    }
}

private final class DesktopFrameAllocator: VNCFramebufferAllocator {
    private let lock = NSRecursiveLock()
    func allocate(size: Int) throws -> UnsafeMutableRawPointer {
        guard size > 0, size <= 64 * 1024 * 1024 else {
            throw DesktopProblem(code: "display_limit", message: "This desktop exceeds the supported display size.")
        }
        return .allocate(byteCount: size, alignment: 16)
    }
    func deallocate(buffer: UnsafeMutableRawPointer) { buffer.deallocate() }
    func lockReadOnly() { lock.lock() }
    func unlockReadOnly() { lock.unlock() }
    func lockReadWrite() { lock.lock() }
    func unlockReadWrite() { lock.unlock() }
}
