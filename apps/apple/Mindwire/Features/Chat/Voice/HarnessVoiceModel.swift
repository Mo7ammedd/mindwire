import AVFoundation
import Observation

@MainActor @Observable
final class HarnessVoiceModel {
    enum Phase { case checking, idle, starting, listening, ended, failed }
    private(set) var phase = Phase.checking
    private(set) var status: HarnessVoiceStatus?
    private(set) var error: String?
    private(set) var microphoneDenied = false
    private(set) var levels: [Float] = []
    private(set) var transcript = ""
    private(set) var transcriptRole = ""
    var selectedVoice = ""
    let chat: ChatModel
    @ObservationIgnored private let audio = HarnessVoiceAudioIO()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var runId: String?
    @ObservationIgnored private var clientId = UUID().uuidString
    @ObservationIgnored private var requestId = UUID().uuidString
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var startupDeadline: Task<Void, Never>?
    @ObservationIgnored private var transcriptItem: String?
    @ObservationIgnored private var transcriptFinished = false

    init(chat: ChatModel) { self.chat = chat }
    var active: Bool { phase == .starting || phase == .listening }
    var canStart: Bool { status?.available == true && status?.capability.supportsConversation == true && !active && chat.canStartVoice }

    func check() async {
        guard !checking, !active else { return }
        checking = true
        phase = .checking
        error = nil
        microphoneDenied = false
        defer { checking = false }
        do {
            guard let session = chat.session else { throw BackendError.message(t("chat.voice.native.reconnect")) }
            status = try await session.voiceStatus()
            try Task.checkCancellation()
            phase = .idle
        } catch {
            if !error.isRequestCancellation { self.error = error.localizedDescription; phase = .failed }
        }
    }

    func start() {
        guard canStart, let session = chat.session else { return }
        phase = .starting
        error = nil
        transcript = ""
        transcriptItem = nil
        transcriptFinished = false
        levels = []
        let operation = UUID()
        let client = clientId
        let request = requestId
        generation = operation
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await AVAudioApplication.requestRecordPermission() else {
                    self.microphoneDenied = true
                    throw ChatVoiceError.microphoneDenied
                }
                guard self.generation == operation else { return }
                let run = try await self.chat.startVoice(requestId: request, clientId: client,
                                                        voice: self.selectedVoice.isEmpty ? nil : self.selectedVoice)
                guard self.generation == operation else {
                    try? await session.voiceControl(runId: run.id, clientId: client, action: "stop")
                    if self.requestId == request { self.requestId = UUID().uuidString; self.clientId = UUID().uuidString }
                    return
                }
                self.runId = run.id
                guard run.status == .running else { throw BackendError.message(t("chat.voice.native.ended")) }
                let stream = try session.voiceEvents(runId: run.id, clientId: client)
                self.eventsTask = Task { [weak self] in
                    do {
                        for try await event in stream {
                            guard let self, self.generation == operation, !Task.isCancelled else { return }
                            try self.receive(event, operation: operation)
                        }
                        if let self, self.generation == operation, self.active {
                            self.end(message: t("chat.voice.native.disconnected"))
                        }
                    } catch {
                        guard let self, self.generation == operation, !error.isRequestCancellation else { return }
                        self.end(message: error.localizedDescription)
                    }
                }
                self.heartbeatTask = Task { [weak self] in
                    do {
                        while let self, self.generation == operation {
                            try await Task.sleep(for: .seconds(5))
                            try Task.checkCancellation()
                            try await session.voiceControl(runId: run.id, clientId: client, action: "heartbeat")
                        }
                    } catch {
                        if let self, self.generation == operation, !error.isRequestCancellation { self.end(message: error.localizedDescription) }
                    }
                }
                self.startupDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    if let self, self.generation == operation, self.phase == .starting { self.end(message: t("chat.voice.native.timedOut")) }
                }
            } catch {
                guard self.generation == operation, !error.isRequestCancellation else { return }
                self.end(message: error.localizedDescription)
            }
        }
    }

    private func receive(_ event: HarnessVoiceEvent, operation: UUID) throws {
        switch event.type {
        case "ready":
            guard phase == .starting, let session = chat.session, let runId else { return }
            startupDeadline?.cancel()
            audio.onLevel = { [weak self] level in
                guard let self, self.generation == operation else { return }
                self.levels.append(level)
                if self.levels.count > ChatVoiceWaveform.barCount { self.levels.removeFirst(self.levels.count - ChatVoiceWaveform.barCount) }
            }
            audio.onInterruption = { [weak self] in self?.end(message: t("chat.voice.native.interrupted")) }
            let input = try audio.start()
            phase = .listening
            let client = clientId
            inputTask = Task { [weak self] in
                var sequence = 0
                do {
                    for try await data in input {
                        try Task.checkCancellation()
                        guard self?.generation == operation else { return }
                        sequence += 1
                        try await session.voiceControl(runId: runId, clientId: client, action: "audio", sequence: sequence, audio: .init(data: data))
                    }
                } catch {
                    if let self, self.generation == operation, !error.isRequestCancellation { self.end(message: error.localizedDescription) }
                }
            }
        case "audio": if let data = event.audio { try audio.play(data) }
        case "listening": audio.interruptPlayback()
        case "transcript":
            let role = event.role ?? transcriptRole
            let changedItem = event.itemId != nil && event.itemId != transcriptItem
            if role == "user" && (transcriptRole != "user" || changedItem) { audio.interruptPlayback() }
            if role != transcriptRole || changedItem || transcriptFinished && event.final != true { transcript = "" }
            transcriptRole = role
            if let id = event.itemId { transcriptItem = id }
            if event.final == true { transcript = event.text ?? transcript; transcriptFinished = true }
            else { transcript += event.text ?? ""; transcriptFinished = false }
            if transcript.count > 4_000 { transcript = String(transcript.suffix(4_000)) }
        case "error": end(message: event.text ?? t("chat.voice.native.failed"))
        case "closed": end()
        default: break
        }
    }

    /// Always releases the local microphone synchronously. A late POST receipt
    /// is stopped by the start task, never turned into a second voice session.
    func end(message: String? = nil) {
        generation = UUID()
        audio.stop()
        eventsTask?.cancel(); eventsTask = nil
        inputTask?.cancel(); inputTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        startupDeadline?.cancel(); startupDeadline = nil
        error = message
        phase = message == nil ? .ended : .failed
        if let runId, let session = chat.session {
            let client = clientId
            Task { try? await session.voiceControl(runId: runId, clientId: client, action: "stop") }
            self.runId = nil
            requestId = UUID().uuidString
            clientId = UUID().uuidString
        }
    }
}
