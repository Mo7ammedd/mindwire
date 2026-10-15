import SwiftUI

/// Shared by Files and Source Control. Keep a snapshot so presenting the picker cannot lose the
/// selection when the native editor resigns focus.
struct SendToAgentPayload: Identifiable {
    let id = UUID()
    let path: String
    let code: String
    var context: String? = nil
    var format = ""

    var draft: String {
        // Selected Markdown can contain its own code fences.
        var fenceLength = 3
        var run = 0
        for character in code {
            run = character == "`" ? run + 1 : 0
            fenceLength = max(fenceLength, run + 1)
        }
        let fence = String(repeating: "`", count: fenceLength)
        let heading = [path, context].compactMap { $0 }.joined(separator: "\n")
        return "\(heading)\n\(fence)\(format)\n\(code)\n\(fence)\n\n"
    }
}

struct SendCodeToAgentButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(t("editor.sendToAgent"), icon: .send)
                .frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
        }
        .buttonStyle(.glassProminent).controlSize(.regular)
        .accessibilityIdentifier("editor.sendToAgent")
    }
}

/// Keep one acknowledged chat per selection, including during the sheet's dismissal animation.
@MainActor @Observable
final class CodeSelectionAgentModel {
    let actions = WorkspaceActions()
    private(set) var selectedAgentId: String?
    private(set) var completed = false
    var isBusy: Bool { actions.running || completed }

    func select(_ agent: Agent, projectId: String, selection: SendToAgentPayload,
                repository: WorkspaceDataRepository, onReady: @escaping (ChatDraftRoute) -> Void) {
        guard !isBusy else { return }
        selectedAgentId = agent.id
        actions.run {
            let chat = try await repository.createChat(
                agentId: agent.id, projectId: projectId, title: (selection.path as NSString).lastPathComponent)
            self.completed = true
            onReady(ChatDraftRoute(chatId: chat.id, draft: selection.draft))
        }
    }
}

private struct CodeSelectionAgentPresenter: ViewModifier {
    @Binding var payload: SendToAgentPayload?
    let projectId: String?
    let onOpenChat: ((String, String) -> Void)?
    @State private var pendingChat: ChatDraftRoute?

    func body(content: Content) -> some View {
        content.sheet(item: $payload, onDismiss: {
            guard let chat = pendingChat else { return }
            pendingChat = nil
            // Navigation starts after the picker finishes dismissing.
            onOpenChat?(chat.chatId, chat.draft)
        }) { selection in
            if let projectId {
                CodeSelectionAgentPicker(projectId: projectId, selection: selection) { chat in
                    pendingChat = chat
                    payload = nil
                }
            }
        }
    }
}

extension View {
    func sendCodeToAgent(_ payload: Binding<SendToAgentPayload?>, projectId: String?,
                         onOpenChat: ((String, String) -> Void)?) -> some View {
        modifier(CodeSelectionAgentPresenter(payload: payload, projectId: projectId, onOpenChat: onOpenChat))
    }
}

/// The daemon creates the chat; its composer opens with a draft for the user's comment.
struct CodeSelectionAgentPicker: View {
    let projectId: String
    let selection: SendToAgentPayload
    let onReady: (ChatDraftRoute) -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var agents: [Agent] = []
    @State private var creating = false
    @State private var model = CodeSelectionAgentModel()

    private var workspaceId: String? { stores.projects.get(projectId)?.workspaceId }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if agents.isEmpty {
                        Text(t("editor.sendToAgent.empty")).foregroundStyle(.secondary)
                    } else {
                        ForEach(agents) { agent in
                            Button { select(agent) } label: {
                                HStack(spacing: Spacing.md) {
                                    AgentLogo(id: agent.agentType, size: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(agent.displayName).lineLimit(1)
                                        Text(agent.typeDisplayName)
                                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: Spacing.sm)
                                    if model.actions.running && model.selectedAgentId == agent.id {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                            .tint(.primary).disabled(model.isBusy)
                            .accessibilityIdentifier("editor.sendToAgent.\(agent.id)")
                        }
                    }
                } footer: {
                    Text(t("editor.sendToAgent.hint"))
                }
                if workspaceId != nil {
                    Section {
                        Button { creating = true } label: {
                            Label(t("editor.sendToAgent.create"), icon: Icon.plus)
                        }
                        .tint(.primary).disabled(model.isBusy)
                    }
                }
            }
            .navigationTitle(t("editor.sendToAgent.pick"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary).disabled(model.isBusy)
                }
            }
            .onAppear(perform: reload)
            .observeWorkspaceCache(reload)
            .workspaceActionAlerts(model.actions)
            .sheet(isPresented: $creating, onDismiss: reload) {
                if let workspaceId { NewAgentScreen(workspaceId: workspaceId) }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isBusy)
    }

    private func reload() { agents = stores.agents(forProjectId: projectId) }

    private func select(_ agent: Agent) {
        model.select(agent, projectId: projectId, selection: selection,
                     repository: stores.workspaceData, onReady: onReady)
    }
}
