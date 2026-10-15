#if targetEnvironment(macCatalyst)
import SwiftUI

struct DesktopNewChatScreen: View {
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ChatDraft()
    @SceneStorage("mindwire.desktop.project") private var projectID = ""
    @SceneStorage("mindwire.desktop.agent") private var agentID = ""
    @State private var creating = false
    @State private var error: String?
    @State private var pairing = false
    @State private var projects: [Project] = []
    @State private var allAgents: [Agent] = []
    @FocusState private var focused: Bool
    private let draftKey = "desktop:new-chat"

    private var project: Project? { projectID.isEmpty ? projects.first : projects.first { $0.id == projectID } }
    private var agents: [Agent] { project.map { project in allAgents.filter { $0.workspaceId == project.workspaceId } } ?? [] }
    private var agent: Agent? { agentID.isEmpty ? agents.first : agents.first { $0.id == agentID } }
    private var hasText: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 24) {
            Text("What can I help with?")
                .font(.title2.weight(.medium))
            VStack(alignment: .leading, spacing: 12) {
                composer
                contextMenu
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Mindwire")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draft = stores.chatDrafts.draft(for: draftKey)
            reloadContext()
        }
        .onChange(of: stores.projects.revision) { reloadContext() }
        .onChange(of: stores.agents.revision) { reloadContext() }
        .onChange(of: repository.all.map(\.id)) { reloadContext() }
        .onDisappear { stores.chatDrafts.persist(draftKey) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stores.chatDrafts.persist(draftKey) } }
        .sheet(isPresented: $pairing) {
            AddServerScreen(presetType: .local) { _ in pairing = false }
                .environment(\.stores, stores)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .bottom, spacing: Spacing.sm) {
                TextField(t("chat.placeholder"), text: $draft.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .disabled(creating)
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift), hasText, !creating else { return .ignored }
                        startChat()
                        return .handled
                    }
                    .accessibilityIdentifier("desktop.composer")
                if creating {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    Button(action: startChat) {
                        AppIcon(Icon.send, size: 16)
                            .foregroundStyle(hasText ? (colorScheme == .dark ? Color.black : .white) : .secondary)
                            .frame(width: 30, height: 30)
                            .background(hasText ? (colorScheme == .dark ? Color.white : .black) : Color.primary.opacity(0.06), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasText)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("desktop.send")
                }
            }
            .padding(.leading, Spacing.lg)
            .padding(.trailing, Spacing.sm)
            .padding(.vertical, 9)
            .chromeGlass(.rect(cornerRadius: Radius.xl, style: .continuous))
            if let error {
                ChatErrorDisclosure(detail: error) { self.error = nil }
            }
        }
    }

    private var contextMenu: some View {
        let selectedProjectID = project?.id
        let selectedAgentID = agent?.id
        return AppMenu {
            Section("Work on") {
                ForEach(projects) { project in
                    Button {
                        projectID = project.id
                        agentID = ""
                    } label: {
                        Label(project.name, icon: selectedProjectID == project.id ? .check : .project)
                    }
                }
            }
            if !agents.isEmpty {
                Section("Connected subscription") {
                    ForEach(agents) { agent in
                        Button { agentID = agent.id } label: {
                            Label(agent.displayName, icon: selectedAgentID == agent.id ? .check : Icon.agents)
                        }
                    }
                }
            }
            Button("Connect a computer…", icon: .plus) { pairing = true }
            Button("Manage computers…", icon: Icon.workspace) { app.selectDesktop(.workspaces) }
        } label: {
            Label(project?.name ?? "Connect a computer", icon: project == nil ? .monitor : .project)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(creating)
        .accessibilityLabel("Choose where Mindwire works")
    }

    private func reloadContext() {
        let workspaceIDs = Set(repository.all.map(\.id))
        projects = stores.projects.list().filter { workspaceIDs.contains($0.workspaceId) }
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
        allAgents = stores.agents.list()
        if projectID.isEmpty, let project { projectID = project.id }
    }

    private func startChat() {
        guard hasText, !creating else { return }
        guard !repository.all.isEmpty else { pairing = true; return }
        guard let project else { app.selectDesktop(.projects); return }
        guard let agent else { app.selectDesktop(.agents); return }
        let text = draft.text
        let source = draft
        let revision = source.revision
        creating = true
        error = nil
        Task { @MainActor in
            defer { creating = false }
            do {
                let chat = try await stores.workspaceData.createChat(agentId: agent.id, projectId: project.id)
                let composer = stores.chatDrafts.draft(for: chat.id)
                // Never replace typing in a conversation that was already opened elsewhere.
                guard composer.text.isEmpty else { app.openChat(chat.id); return }
                composer.text = text
                stores.chatDrafts.persist(chat.id)
                source.clearSubmitted(revision: revision)
                stores.chatDrafts.persist(draftKey)
                app.desktopSubmission = .init(chatID: chat.id, revision: composer.revision)
                app.openChat(chat.id)
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
