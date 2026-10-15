@preconcurrency import AVFoundation
import Foundation

/// Duplex PCM for a harness voice session. This never creates an attachment or a
/// recording file. The bounded stream stops on congestion instead of replaying
/// old speech several seconds after it was spoken.
@MainActor
final class HarnessVoiceAudioIO {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lease = ChatVoiceAudioLease()
    private let speakerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var capture: HarnessVoiceCapturePipeline?
    private var observers: [NSObjectProtocol] = []
    private var running = false
    private var queuedFrames = 0
    private var playbackGeneration = UUID()
    private var playbackConverter: AVAudioConverter?
    var onLevel: ((Float) -> Void)?
    var onInterruption: (() -> Void)?

    func start() throws -> AsyncThrowingStream<Data, Error> {
        guard !running else { throw ChatVoiceError.audioBusy }
        try lease.activate(recording: true, realtime: true)
        do {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw ChatVoiceError.recordingFailed }
            let pipeline = try HarnessVoiceCapturePipeline(input: format) { [weak self] level in
                Task { @MainActor [weak self] in self?.onLevel?(level) }
            }
            capture = pipeline
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: speakerFormat)
            input.installTap(onBus: 0, bufferSize: 2_400, format: format) { buffer, _ in pipeline.receive(buffer) }
            running = true
            engine.prepare()
            try engine.start()
            player.play()
            observeInterruptions()
            return pipeline.stream
        } catch { stop(); throw error }
    }

    func play(_ audio: HarnessVoiceAudio) throws {
        guard running, !audio.data.isEmpty else { return }
        guard (8_000...48_000).contains(audio.sampleRate), (1...2).contains(audio.channels),
              audio.data.count <= 192_000, audio.data.count % (2 * audio.channels) == 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(audio.sampleRate),
                                         channels: AVAudioChannelCount(audio.channels), interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.data.count / (2 * audio.channels))),
              let channels = source.floatChannelData else {
            throw BackendError.message(t("chat.voice.native.invalidAudio"))
        }
        source.frameLength = source.frameCapacity
        audio.data.withUnsafeBytes { bytes in
            for frame in 0..<Int(source.frameLength) {
                for channel in 0..<audio.channels {
                    let offset = (frame * audio.channels + channel) * 2
                    let sample = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                    channels[channel][frame] = Float(sample) / 32_768
                }
            }
        }
        let output: AVAudioPCMBuffer
        if format == speakerFormat {
            output = source
        } else {
            if playbackConverter?.inputFormat != format {
                playbackConverter = AVAudioConverter(from: format, to: speakerFormat)
                playbackConverter?.primeMethod = .none
            }
            guard let converter = playbackConverter,
                  let converted = AVAudioPCMBuffer(pcmFormat: speakerFormat,
                    frameCapacity: AVAudioFrameCount(ceil(Double(source.frameLength) * 24_000 / format.sampleRate)) + 32) else {
                throw BackendError.message(t("chat.voice.native.invalidAudio"))
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                guard !supplied else { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return source
            }
            guard error == nil, status != .error else { throw error ?? BackendError.message(t("chat.voice.playbackFailed")) as NSError }
            output = converted
        }
        let frames = Int(output.frameLength)
        guard frames > 0 else { return }
        // Voice models can generate speech faster than real-time playback. Bound
        // the reply without treating a normal sentence as network congestion.
        guard queuedFrames + frames <= 24_000 * 30 else { throw BackendError.message(t("chat.voice.native.tooSlow")) }
        queuedFrames += frames
        let generation = playbackGeneration
        player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
            }
        }
    }

    func interruptPlayback() {
        playbackGeneration = UUID()
        queuedFrames = 0
        playbackConverter?.reset()
        player.stop()
        if running { player.play() }
    }

    func stop() {
        capture?.finish()
        capture = nil
        if running { engine.inputNode.removeTap(onBus: 0) }
        running = false
        player.stop()
        engine.stop()
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        playbackGeneration = UUID()
        queuedFrames = 0
        playbackConverter = nil
        lease.release()
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.onInterruption?() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.onInterruption?() }
        })
    }
}

/// The audio render callback never waits for a network request or touches UI.
/// Converter state and the small packet buffer are serialized by this lock.
private final class HarnessVoiceCapturePipeline: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var pending = Data()
    private var finished = false
    private let onLevel: @Sendable (Float) -> Void

    init(input: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: format) else { throw ChatVoiceError.recordingFailed }
        self.converter = converter
        self.format = format
        self.onLevel = onLevel
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(6))
        stream = pair.stream
        continuation = pair.continuation
    }

    func receive(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let output = AVAudioPCMBuffer(pcmFormat: format,
            frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 24_000 / input.format.sampleRate)) + 32) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, let samples = output.int16ChannelData?[0] else {
            finished = true; continuation.finish(throwing: error ?? ChatVoiceError.recordingFailed as NSError); return
        }
        let count = Int(output.frameLength)
        var square: Double = 0
        for index in 0..<count { let value = Double(samples[index]) / 32_768; square += value * value }
        onLevel(Float(min(1, sqrt(square / Double(max(1, count))) * 5)))
        pending.append(Data(bytes: samples, count: count * 2))
        let batchBytes = 9_600 // 200 ms; native speech packets stay ordered.
        while pending.count >= batchBytes {
            let batch = pending.prefix(batchBytes)
            pending.removeFirst(batchBytes)
            if case .dropped = continuation.yield(Data(batch)) {
                finished = true
                continuation.finish(throwing: BackendError.message(t("chat.voice.native.tooSlow")))
                return
            }
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        pending.removeAll(keepingCapacity: false)
        continuation.finish()
    }
}
