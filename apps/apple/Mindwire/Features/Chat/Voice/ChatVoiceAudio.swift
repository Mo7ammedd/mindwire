import AVFoundation
import Foundation

@MainActor
protocol ChatVoiceCapturing: AnyObject {
    var elapsed: TimeInterval { get }
    var onInterruption: ((String) -> Void)? { get set }
    func start() throws
    func level() -> Float
    func stop()
}

/// One microphone/playback owner across windows. Restore the app's audio settings on exit.
@MainActor
final class ChatVoiceAudioLease {
    private static var owner: UUID?
    private let id = UUID()
    private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    func activate(recording: Bool, realtime: Bool = false) throws {
        guard Self.owner == nil || Self.owner == id else { throw ChatVoiceError.audioBusy }
        let session = AVAudioSession.sharedInstance()
        if previous == nil { previous = (session.category, session.mode, session.categoryOptions) }
        Self.owner = id
        do {
            if recording {
                try session.setCategory(.playAndRecord, mode: realtime ? .voiceChat : .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            } else {
                try session.setCategory(.playback, mode: .spokenAudio)
            }
            try session.setActive(true)
        } catch {
            release()
            throw ChatVoiceError.audioBusy
        }
    }

    func release() {
        guard Self.owner == id else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let previous { try? session.setCategory(previous.0, mode: previous.1, options: previous.2) }
        previous = nil
        Self.owner = nil
    }
}

@MainActor
final class ChatVoiceAudioCapture: NSObject, ChatVoiceCapturing, AVAudioRecorderDelegate {
    private let url: URL
    private let lease = ChatVoiceAudioLease()
    private var recorder: AVAudioRecorder?
    private var observers: [NSObjectProtocol] = []
    var onInterruption: ((String) -> Void)?
    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    init(url: URL) { self.url = url }

    func start() throws {
        try lease.activate(recording: true)
        do {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else { throw ChatVoiceError.recordingFailed }
            self.recorder = recorder
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
            observeInterruptions()
        } catch {
            stop()
            throw error
        }
    }

    func level() -> Float {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        return ChatVoiceWaveform.normalizedLevel(decibels: recorder.averagePower(forChannel: 0))
    }

    func stop() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        lease.release()
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.onInterruption?(t("chat.voice.interrupted")) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in self?.onInterruption?(t("chat.voice.microphoneDisconnected")) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onInterruption?(t("chat.voice.interrupted")) }
        })
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in self?.onInterruption?(t("chat.voice.interrupted")) }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onInterruption?(t("chat.voice.interrupted")) }
    }
}

enum ChatVoiceWaveform {
    static let barCount = 64

    static func normalizedLevel(decibels: Float) -> Float {
        guard decibels.isFinite, decibels > -55 else { return 0 }
        return min(1, max(0, pow(10, decibels / 40)))
    }

    /// Peak-preserving reduction for playback; even a short sound remains visible.
    static func summary(_ levels: [Float], bars: Int = barCount) -> [Float] {
        guard bars > 0, !levels.isEmpty else { return [] }
        guard levels.count > bars else { return levels }
        return (0..<bars).map { index in
            let start = index * levels.count / bars
            let end = (index + 1) * levels.count / bars
            return levels[start..<end].max() ?? 0
        }
    }
}

enum ChatVoiceError: LocalizedError {
    case microphoneDenied, audioBusy, recordingFailed, noRecording, transcriptionUnavailable, noSpeech, tooLarge

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: t("chat.voice.microphoneDenied")
        case .audioBusy: t("chat.voice.audioBusy")
        case .recordingFailed: t("chat.voice.recordingFailed")
        case .noRecording: t("chat.voice.noRecording")
        case .transcriptionUnavailable: t("chat.voice.transcriptionUnavailable")
        case .noSpeech: t("chat.voice.noSpeech")
        case .tooLarge: t("chat.voice.tooLarge")
        }
    }
}
