import AVFoundation
import Observation
import UIKit

struct ChatVoiceDraft {
    let text: String
    var attachment: DaemonAttachment?
}

@MainActor
struct ChatVoiceDependencies {
    var requestPermission: () async -> Bool
    var makeCapture: (URL) throws -> any ChatVoiceCapturing
    var transcription: any ChatVoiceTranscribing

    static var live: Self {
        .init(requestPermission: { await AVAudioApplication.requestRecordPermission() },
              makeCapture: { ChatVoiceAudioCapture(url: $0) }, transcription: ChatVoiceTranscription())
    }
}

@MainActor @Observable
final class ChatVoiceModel: NSObject, AVAudioPlayerDelegate {
    enum Phase { case idle, requestingPermission, recording, transcribing, review, failed }
    static let maximumDuration: TimeInterval = 600
    static let languagePreference = "mindwire.chat.voiceLanguage"

    private(set) var phase = Phase.idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = []
    private(set) var progress = ChatVoiceTranscriptionProgress()
    private(set) var isPlaying = false
    private(set) var playbackPosition: TimeInterval = 0
    private(set) var microphoneDenied = false
    var transcript = ""
    var includeRecording = false
    var notice: String?
    var error: String?
    let languages: [ChatVoiceLanguage]
    var language: String

    @ObservationIgnored private let dependencies: ChatVoiceDependencies
    @ObservationIgnored private var capture: (any ChatVoiceCapturing)?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let playbackLease = ChatVoiceAudioLease()
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var recordedLevels: [Float] = []
    @ObservationIgnored private var requestedTranscription = false
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    init(dependencies: ChatVoiceDependencies? = nil, language: String? = nil) {
        self.dependencies = dependencies ?? .live
        let choices = ChatVoiceLanguage.choices
        languages = choices
        self.language = language ?? ChatVoiceLanguage.preferred(
            saved: UserDefaults.standard.string(forKey: Self.languagePreference),
            keyboard: UITextInputMode.activeInputModes.first?.primaryLanguage, choices: choices)
    }

    var hasRecording: Bool { recordingURL != nil && elapsed >= 0.2 }
    var canAdd: Bool { phase == .review && (!transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includeRecording && hasRecording) }
    var durationLabel: String { Self.duration(elapsed) }
    var playbackLabel: String { Self.duration(isPlaying || playbackPosition > 0 ? playbackPosition : elapsed) }
    var languageLabel: String { languages.first { $0.id == language }?.label ?? language }

    /// Returning from Settings never starts the microphone without another tap.
    func refreshMicrophonePermission() {
        if microphoneDenied && AVAudioApplication.shared.recordPermission == .granted {
            microphoneDenied = false
            error = nil
            phase = .idle
        }
    }

    /// Idempotent start: repeated taps and late permission callbacks cannot open a second recorder.
    func start() {
        guard phase == .idle || phase == .review || phase == .failed else { return }
        cancel()
        phase = .requestingPermission
        let id = operationID
        let request = dependencies.requestPermission
        startupTask = Task { [weak self] in
            let granted = await request()
            guard let self, self.operationID == id, !Task.isCancelled else { return }
            guard granted else {
                self.microphoneDenied = true
                self.error = ChatVoiceError.microphoneDenied.localizedDescription
                self.phase = .failed
                return
            }
            self.beginCapture(id: id)
        }
    }

    private func beginCapture(id: UUID) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MindwireVoice", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
            self.directory = directory
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
            let url = directory.appendingPathComponent("Recording.m4a")
            let capture = try dependencies.makeCapture(url)
            self.capture = capture
            capture.onInterruption = { [weak self] reason in
                guard let self, self.operationID == id, self.phase == .recording else { return }
                self.finishRecording(notice: reason)
            }
            try capture.start()
            recordingURL = url
            phase = .recording
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    self?.sample()
                }
            }
        } catch {
            capture?.stop(); capture = nil
            removeRecording()
            self.error = error.localizedDescription
            phase = .failed
        }
    }

    private func sample() {
        guard phase == .recording, let capture else { return }
        elapsed = min(Self.maximumDuration, max(elapsed, capture.elapsed))
        let level = min(1, max(0, capture.level()))
        if recordedLevels.count < Int(Self.maximumDuration * 20) + 1 { recordedLevels.append(level) }
        levels = Array((levels + [level]).suffix(ChatVoiceWaveform.barCount))
        if elapsed >= Self.maximumDuration { finishRecording(notice: t("chat.voice.limit")) }
    }

    func finishRecording(notice: String? = nil, transcribe: Bool = false) {
        guard phase == .recording, let capture else { return }
        elapsed = min(Self.maximumDuration, max(elapsed, capture.elapsed))
        meterTask?.cancel(); meterTask = nil
        capture.onInterruption = nil
        capture.stop(); self.capture = nil
        levels = ChatVoiceWaveform.summary(recordedLevels)
        self.notice = notice
        phase = .review
        guard hasRecording else {
            removeRecording()
            error = ChatVoiceError.noRecording.localizedDescription
            phase = .failed
            return
        }
        includeRecording = true
        if transcribe { transcribeRecording() }
    }

    func transcribeRecording() {
        guard phase == .review, let recordingURL else { return }
        stopPlayback()
        requestedTranscription = true
        error = nil
        progress = .init(preparing: true)
        phase = .transcribing
        let id = operationID
        let locale = Locale(identifier: language)
        let transcriber = dependencies.transcription
        transcriptionTask = Task { [weak self] in
            do {
                let text = try await transcriber.transcribe(url: recordingURL, locale: locale) { [weak self] value in
                    guard let self, self.operationID == id, self.phase == .transcribing else { return }
                    self.progress = value
                } partial: { [weak self] text in
                    guard let self, self.operationID == id, self.phase == .transcribing else { return }
                    self.transcript = text
                }
                guard let self, self.operationID == id, !Task.isCancelled else { return }
                self.deadlineTask?.cancel(); self.deadlineTask = nil
                self.transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if self.transcript.isEmpty { self.includeRecording = true }
                self.phase = .review
                if self.transcript.isEmpty { self.error = ChatVoiceError.noSpeech.localizedDescription }
            } catch {
                guard let self, self.operationID == id, !Task.isCancelled else { return }
                self.deadlineTask?.cancel(); self.deadlineTask = nil
                if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.includeRecording = true }
                self.error = (error as? ChatVoiceError)?.localizedDescription ?? t("chat.voice.transcriptionFailed")
                self.phase = .review
            }
        }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            guard let self, self.operationID == id, self.phase == .transcribing else { return }
            self.keepRecordingInstead()
            self.error = t("chat.voice.transcriptionTimedOut")
        }
    }

    func keepRecordingInstead() {
        guard phase == .transcribing else { return }
        operationID = UUID()
        transcriptionTask?.cancel(); transcriptionTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        phase = .review
        includeRecording = true
    }

    func changeLanguage(_ value: String) {
        guard language != value else { return }
        language = value
        UserDefaults.standard.set(value, forKey: Self.languagePreference)
        if phase == .transcribing { keepRecordingInstead() }
        if phase == .review && requestedTranscription { transcript = ""; transcribeRecording() }
    }

    func suspend() {
        if phase == .recording { finishRecording(notice: t("chat.voice.kept"), transcribe: false) }
        if phase == .transcribing { keepRecordingInstead(); notice = t("chat.voice.kept") }
        if phase == .requestingPermission { cancel() }
        stopPlayback()
    }

    func draft() async throws -> ChatVoiceDraft {
        guard canAdd else { throw ChatVoiceError.noRecording }
        let id = operationID
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard includeRecording, let recordingURL else { return .init(text: text) }
        let task = Task.detached(priority: .userInitiated) {
            let bytes = try recordingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes <= ChatImageDraft.maximumFileBytes else { throw ChatVoiceError.tooLarge }
            let data = try Data(contentsOf: recordingURL)
            guard !data.isEmpty else { throw ChatVoiceError.noRecording }
            guard data.count <= ChatImageDraft.maximumFileBytes else { throw ChatVoiceError.tooLarge }
            return data
        }
        let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard operationID == id, !Task.isCancelled else { throw CancellationError() }
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return .init(text: text, attachment: .init(name: "Voice \(timestamp).m4a", mime: "audio/mp4", data: data))
    }

    func togglePlayback() {
        if isPlaying {
            player?.pause()
            playbackTask?.cancel(); playbackTask = nil
            isPlaying = false
            playbackLease.release()
            return
        }
        guard let recordingURL, phase == .review else { return }
        do {
            try playbackLease.activate(recording: false)
            let player = try player ?? AVAudioPlayer(contentsOf: recordingURL)
            player.delegate = self
            guard player.play() else { throw ChatVoiceError.recordingFailed }
            self.player = player
            isPlaying = true
            playbackPosition = player.currentTime
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    self?.playbackPosition = self?.player?.currentTime ?? 0
                }
            }
        } catch {
            stopPlayback()
            self.error = t("chat.voice.playbackFailed")
        }
    }

    func stopPlayback() {
        playbackTask?.cancel(); playbackTask = nil
        player?.delegate = nil; player?.stop(); player = nil
        isPlaying = false; playbackPosition = 0
        playbackLease.release()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stopPlayback() }
    }

    func cancel() {
        operationID = UUID()
        startupTask?.cancel(); startupTask = nil
        transcriptionTask?.cancel(); transcriptionTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        meterTask?.cancel(); meterTask = nil
        capture?.onInterruption = nil; capture?.stop(); capture = nil
        stopPlayback()
        removeRecording()
        transcript = ""; elapsed = 0; levels = []; recordedLevels = []; requestedTranscription = false
        includeRecording = false; microphoneDenied = false; error = nil; notice = nil
        progress = .init(); phase = .idle
    }

    private func removeRecording() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil; recordingURL = nil
    }

    private static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
