import SwiftUI
import Observation

@MainActor @Observable
final class ChatHandoffDraft: Identifiable {
    let id = UUID()
    let agents: [Agent]
    var targetAgentId: String
    var task = ""
    var context = ""
    private(set) var preview: DaemonHandoffPreview?
    private(set) var loading = false
    private(set) var submitting = false
    private(set) var error: String?
    private(set) var submitted: ChatHandoffRequest?
    private(set) var completedChatId: String?
    @ObservationIgnored private let loadPreview: () async throws -> DaemonHandoffPreview
    @ObservationIgnored private let perform: (ChatHandoffRequest) async throws -> String

    init(agents: [Agent], loadPreview: @escaping () async throws -> DaemonHandoffPreview,
         perform: @escaping (ChatHandoffRequest) async throws -> String) {
        self.agents = agents
        targetAgentId = agents.first?.id ?? ""
        self.loadPreview = loadPreview
        self.perform = perform
    }

    var canSubmit: Bool {
        preview != nil && !submitting && !loading && !targetAgentId.isEmpty
            && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && task.utf8.count <= 4096 && context.utf8.count <= 32768
    }

    func load() async {
        guard preview == nil, !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let value = try await loadPreview()
            context = value.context
            preview = value
        } catch { self.error = error.localizedDescription }
    }

    func send() async -> String? {
        if let completedChatId { return completedChatId }
        guard canSubmit else { return nil }
        submitting = true
        error = nil
        defer { submitting = false }
        let request = submitted ?? ChatHandoffRequest(newChatId: newId(), requestId: UUID().uuidString,
            targetAgentId: targetAgentId, task: task.trimmingCharacters(in: .whitespacesAndNewlines), context: context)
        submitted = request
        do {
            let id = try await perform(request)
            completedChatId = id
            return id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

struct ChatHandoffSheet: View {
    @Bindable var draft: ChatHandoffDraft
    let onSent: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if draft.agents.isEmpty {
                    Text(t("chat.handoff.noAgents"))
                } else {
                    Section {
                        Picker(t("chat.handoff.agent"), selection: $draft.targetAgentId) {
                            ForEach(draft.agents) { agent in
                                Text("\(agent.displayName) · \(agent.typeDisplayName)").tag(agent.id)
                            }
                        }
                        TextField(t("chat.handoff.task"), text: $draft.task, axis: .vertical)
                            .lineLimit(3...6)
                        if draft.task.utf8.count > 4096 { Text(t("chat.handoff.taskTooLong")).foregroundStyle(.red) }
                    } footer: { Text(t("chat.handoff.detail")) }
                    .disabled(draft.submitted != nil)
                    Section(t("chat.handoff.context")) {
                        if draft.loading { ProgressView() }
                        else if draft.preview != nil {
                            TextEditor(text: $draft.context)
                                .frame(minHeight: 200)
                                .disabled(draft.submitted != nil)
                                .accessibilityLabel(t("chat.handoff.context"))
                            if draft.context.utf8.count > 32768 { Text(t("chat.handoff.contextTooLong")).foregroundStyle(.red) }
                            if draft.preview?.truncated == true { Text(t("chat.handoff.partial")).foregroundStyle(.secondary) }
                            if draft.preview?.historySource == "recorded" { Text(t("chat.handoff.fallback")).foregroundStyle(.secondary) }
                        }
                    }
                }
                if let error = draft.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if draft.preview == nil { Button(t("common.retry")) { Task { await draft.load() } } }
                    } footer: {
                        if draft.submitted != nil { Text(t("chat.handoff.retry")) }
                    }
                }
            }
            .navigationTitle(t("chat.handoff.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.disabled(draft.submitting)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { if let id = await draft.send() { onSent(id) } }
                    } label: {
                        if draft.submitting { ProgressView().chatActivityTint() }
                        else { Text(t(draft.submitted == nil ? "chat.handoff.start" : "common.retry")) }
                    }
                    .disabled(!draft.canSubmit)
                }
            }
            .task { if !draft.agents.isEmpty { await draft.load() } }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(draft.submitting)
    }
}
