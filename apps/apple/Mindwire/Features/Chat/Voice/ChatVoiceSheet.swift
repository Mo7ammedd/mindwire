import SwiftUI

/// Recording, review and file fallback share one sheet. Nothing sends until the user sends the draft.
struct ChatVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice: ChatVoiceModel
    @State private var adding = false
    @State private var addError: String?
    @State private var detent = PresentationDetent.medium
    let nativeAudio: Bool
    let add: (ChatVoiceDraft) throws -> Void

    init(model: ChatVoiceModel? = nil, nativeAudio: Bool = false, add: @escaping (ChatVoiceDraft) throws -> Void) {
        _voice = State(initialValue: model ?? ChatVoiceModel.forChat())
        self.nativeAudio = nativeAudio
        self.add = add
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    recordingCard
                    if let addError { ChatErrorDisclosure(title: t("chat.voice.addFailed"), detail: addError) { self.addError = nil } }
                    content
                    if let notice = voice.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.lg)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaBar(edge: .bottom) { controls.padding(Spacing.lg).frame(maxWidth: 600).frame(maxWidth: .infinity) }
            .navigationTitle(t("chat.voice.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary)
                        .accessibilityIdentifier("chat.voice.cancel")
                }
                AppToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(t("chat.voice.language"), selection: Binding(get: { voice.language }, set: voice.changeLanguage)) {
                            ForEach(voice.languages) { Text($0.label).tag($0.id) }
                        }
                    } label: { AppIcon(.globe, size: 22).foregroundStyle(.primary) }
                    .accessibilityLabel(t("chat.voice.language"))
                    .accessibilityValue(voice.languageLabel)
                    .accessibilityIdentifier("chat.voice.language")
                    .disabled(adding)
                }
            }
        }
        .presentationDetents([.medium, .height(540), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(adding)
        .task { voice.start() }
        .onDisappear { voice.cancel() }
        .onChange(of: voice.phase) { _, phase in
            // Review has more controls than recording. Keep its secondary action above
            // the fixed footer on smaller phones instead of under the scroll-edge blur.
            if phase == .review && detent == .medium { detent = .height(540) }
        }
        .onChange(of: scenePhase) { _, value in
            if value == .background { voice.suspend() }
            if value == .active { voice.refreshMicrophonePermission() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: voice.phase == .recording)
    }

    private var recordingCard: some View {
        VStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                if voice.phase == .recording {
                    Circle().fill(.red).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Text(t(voice.phase == .recording ? "chat.voice.recording" : "chat.voice.recordingLabel"))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: Spacing.sm)
                Text(voice.playbackLabel).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.voice.duration")
            }
            HStack(spacing: Spacing.md) {
                if voice.phase == .review && voice.hasRecording {
                    Button { voice.togglePlayback() } label: {
                        AppIcon(voice.isPlaying ? .pause : .play, size: 22)
                            .foregroundStyle(.primary).frame(width: 44, height: 44)
                            .background(Color.primary.opacity(0.07), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t(voice.isPlaying ? "chat.voice.pause" : "chat.voice.play"))
                    .accessibilityIdentifier("chat.voice.play")
                }
                ChatVoiceWaveformView(levels: voice.levels, playback: voice.isPlaying ? voice.playbackPosition / max(0.1, voice.elapsed) : nil)
                    .frame(height: 68)
                    .accessibilityIdentifier("chat.voice.waveform")
            }
        }
        .padding(Spacing.lg)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 24))
    }

    @ViewBuilder private var content: some View {
        switch voice.phase {
        case .idle:
            Text(t("chat.voice.hint")).font(.subheadline).foregroundStyle(.secondary)
        case .requestingPermission:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(t("chat.voice.starting")).font(.subheadline).foregroundStyle(.secondary)
            }
        case .recording:
            Text(t("chat.voice.hint")).font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .transcribing:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(t(voice.progress.preparing ? "chat.voice.preparingSpeech" : "chat.voice.transcribing"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let fraction = voice.progress.fraction {
                        Spacer()
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let fraction = voice.progress.fraction { ProgressView(value: fraction).tint(.primary) }
                if !voice.transcript.isEmpty {
                    Text(voice.transcript).font(.body).naturalChatDirection(voice.transcript, fillWidth: true).lineLimit(4)
                }
            }
        case .review:
            VStack(alignment: .leading, spacing: Spacing.md) {
                if let error = voice.error {
                    ChatErrorDisclosure(title: t("chat.voice.transcriptionTitle"), detail: error) { voice.error = nil }
                }
                TextField(t("chat.voice.transcriptPlaceholder"), text: $voice.transcript, axis: .vertical)
                    .font(.body).lineLimit(1...5).naturalChatDirection(voice.transcript)
                    .padding(Spacing.md)
                    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 16))
                    .accessibilityLabel(t("chat.voice.transcript"))
                    .accessibilityIdentifier("chat.voice.transcript")
                if !voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !voice.includeRecording {
                    Toggle(t("chat.voice.attachRecording"), isOn: $voice.includeRecording)
                        .font(.subheadline).tint(Palette.accent)
                        .accessibilityIdentifier("chat.voice.attachRecording")
                }
                if voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(t(nativeAudio ? "chat.voice.nativeHint" : "chat.voice.fileHint"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(t("chat.voice.retryTranscription")) { voice.transcribeRecording() }
                    .font(.subheadline).tint(.primary)
                    .accessibilityIdentifier("chat.voice.transcribe")
            }
        case .failed:
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(t(voice.microphoneDenied ? "chat.voice.permissionTitle" : "chat.voice.failedTitle")).font(.headline)
                Text(voice.error ?? t("chat.voice.recordingFailed")).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch voice.phase {
        case .recording:
            Button { voice.finishRecording() } label: {
                Label(t("chat.voice.stop"), icon: .stop).font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Palette.accent)
            .accessibilityIdentifier("chat.voice.stop")
        case .transcribing:
            Button(t("chat.voice.useRecording")) { voice.keepRecordingInstead() }
                .font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.primary)
                .accessibilityIdentifier("chat.voice.useRecording")
        case .review:
            HStack(spacing: Spacing.md) {
                Button { voice.start() } label: {
                    AppIcon(.microphone, size: 22).frame(width: 48, height: 48)
                        .background(Color.primary.opacity(0.07), in: .circle)
                }
                .buttonStyle(.plain).foregroundStyle(.primary).disabled(adding)
                .accessibilityLabel(t("chat.voice.again"))
                .accessibilityIdentifier("chat.voice.again")
                Button(action: addDraft) {
                    HStack(spacing: Spacing.sm) {
                        if adding { ProgressView().tint(.white) }
                        Text(t("chat.voice.add")).font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Palette.accent)
                .disabled(!voice.canAdd || adding)
                .accessibilityIdentifier("chat.voice.add")
            }
        case .failed:
            Button(t(voice.microphoneDenied ? "chat.voice.openSettings" : "common.retry")) {
                if voice.microphoneDenied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                else { voice.start() }
            }
            .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Palette.accent)
            .accessibilityIdentifier("chat.voice.retry")
        case .idle:
            Button(t("chat.voice.record")) { voice.start() }
                .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Palette.accent)
        case .requestingPermission:
            EmptyView()
        }
    }

    private func addDraft() {
        guard voice.canAdd, !adding else { return }
        adding = true
        addError = nil
        Task {
            defer { adding = false }
            do {
                try add(await voice.draft())
                dismiss()
            } catch {
                if !error.isRequestCancellation { addError = error.localizedDescription }
            }
        }
    }
}

struct ChatVoiceWaveformView: View {
    let levels: [Float]
    var playback: Double?

    var body: some View {
        Canvas { context, size in
            let count = ChatVoiceWaveform.barCount
            let step = size.width / CGFloat(count)
            let width = max(1.5, step * 0.5)
            let padding = max(0, count - levels.count)
            for index in 0..<count {
                let value = index < padding ? 0 : CGFloat(levels[min(levels.count - 1, index - padding)])
                let height = max(3, min(1, value) * size.height)
                let rect = CGRect(x: CGFloat(index) * step + (step - width) / 2, y: (size.height - height) / 2,
                                  width: width, height: height)
                let played = playback.map { Double(index) / Double(count) < $0 } ?? false
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                             with: .color(played ? Palette.accent : .primary.opacity(playback == nil ? 0.8 : 0.3)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("chat.voice.waveform"))
    }
}

extension ChatVoiceModel {
    static func forChat() -> ChatVoiceModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--app-store-preview"),
           let scenario = ProcessInfo.processInfo.environment["MINDWIRE_VOICE_FIXTURE"] {
            return ChatVoicePreview.model(scenario: scenario)
        }
        #endif
        return ChatVoiceModel()
    }
}
