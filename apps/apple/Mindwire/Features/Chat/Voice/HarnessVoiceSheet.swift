import SwiftUI

struct HarnessVoiceSheet: View {
    @Environment(\.chatAccent) private var accent
    let agentType: AgentID?
    let agentId: String?
    let name: String
    let recordFile: () -> Void
    @State private var voice: HarnessVoiceModel
    @State private var showingAccount = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    init(chat: ChatModel, agentType: AgentID?, agentId: String?, name: String, recordFile: @escaping () -> Void) {
        _voice = State(initialValue: HarnessVoiceModel(chat: chat))
        self.agentType = agentType
        self.agentId = agentId
        self.name = name
        self.recordFile = recordFile
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    AppLogo(size: 48)
                        .frame(width: 76, height: 76)
                        .background(Color.primary.opacity(0.045), in: .circle)
                        .padding(.top, Spacing.md)
                    VStack(spacing: Spacing.sm) {
                        Text(t("chat.voice.native.title", ["agent": name])).font(.title3.weight(.semibold))
                        if voice.phase == .checking || voice.phase == .starting {
                            HStack(spacing: Spacing.sm) {
                                ProgressView().chatActivityTint().controlSize(.small)
                                Text(t(voice.phase == .checking ? "chat.voice.native.checking" : "chat.voice.native.connecting"))
                            }.font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text(voice.active ? t("chat.voice.native.listening") : voice.status?.detail ?? t("chat.voice.native.hint"))
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .accessibilityIdentifier("chat.voice.native.status")
                        }
                    }
                    if voice.active {
                        ChatVoiceWaveformView(levels: voice.levels).frame(height: 64)
                            .accessibilityIdentifier("chat.voice.native.waveform")
                        if !voice.transcript.isEmpty {
                            Text(voice.transcript).font(.body).naturalChatDirection(voice.transcript, fillWidth: true)
                                .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let error = voice.error {
                        ChatErrorDisclosure(title: t("chat.voice.native.failed"), detail: error)
                        Button(t(voice.microphoneDenied ? "chat.voice.openSettings" : "common.retry")) {
                            if voice.microphoneDenied { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                            else { Task { await voice.check() } }
                        }
                        .tint(.primary).accessibilityIdentifier("chat.voice.native.retry")
                    }
                    if !voice.active {
                        if voice.status?.code == "voice_account_required", agentId != nil {
                            Button(t("agentAuth.section")) { showingAccount = true }.tint(.primary)
                        }
                        if voice.status?.available == true, !voice.chat.canStartVoice {
                            Text(t("chat.voice.native.busy")).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let choices = voice.status?.voices, !choices.isEmpty {
                            Picker(t("chat.voice.native.speaker"), selection: $voice.selectedVoice) {
                                Text(t("chat.voice.native.default")).tag("")
                                ForEach(choices, id: \.self) { Text($0.capitalized).tag($0) }
                            }.pickerStyle(.menu).tint(.primary)
                        }
                        Button {
                            voice.end(); recordFile()
                        } label: {
                            HStack(spacing: Spacing.md) {
                                AppIcon(.microphone, size: 22).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(t("chat.voice.native.recordFile")).font(.subheadline.weight(.medium))
                                    Text(t("chat.voice.native.fileDescription")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                AppIcon(.chevronRight, size: 14).foregroundStyle(.tertiary)
                            }
                            .padding(Spacing.md).background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 20))
                        }
                        .buttonStyle(.plain).foregroundStyle(.primary)
                        .accessibilityIdentifier("chat.voice.native.recordFile")
                    }
                }
                .padding(Spacing.lg).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .safeAreaBar(edge: .bottom) {
                if voice.active {
                    Button { voice.end() } label: {
                        Label(t("chat.voice.native.end"), icon: .stop).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.red)
                    .accessibilityIdentifier("chat.voice.native.end")
                    .padding(Spacing.lg).frame(maxWidth: 560).frame(maxWidth: .infinity)
                } else if voice.status?.available == true {
                    Button { voice.start() } label: {
                        Label(t("chat.voice.native.start"), icon: .microphone).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(accent)
                    .disabled(!voice.canStart)
                    .accessibilityIdentifier("chat.voice.native.start")
                    .padding(Spacing.lg).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(t("chat.voice.native.label")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { voice.end(); dismiss() }.tint(.primary) }
            }
        }
        .presentationDetents([.height(560), .large]).presentationDragIndicator(.visible)
        .task { await voice.check() }
        .onDisappear { voice.end() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { voice.end() } }
        .sheet(isPresented: $showingAccount, onDismiss: { Task { await voice.check() } }) {
            if let agentId {
                NavigationStack {
                    AgentAuthenticationScreen(agentId: agentId, session: voice.chat.session)
                        .toolbar { AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { showingAccount = false }.tint(.primary) } }
                }
            }
        }
    }
}
