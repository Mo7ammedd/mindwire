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
        VStack(spacing: 0) {
            Spacer(minLength: 32)
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Text("What can I help with?")
                        .font(.system(size: 32, weight: .medium, design: .rounded))
                    Text("An idea, a task, a little less on your plate.")
                        .font(.body).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                composer
                suggestions
            }
            .frame(maxWidth: 740)
            .padding(.horizontal, 40)
            Spacer(minLength: 48)
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.caption)
                Text("Your computer. Your subscriptions. One Mindwire.").font(.caption)
            }
            .foregroundStyle(.tertiary)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationTitle("New chat")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Computers", systemImage: "desktopcomputer") { app.selectDesktop(.workspaces) }
                    Button("Settings", systemImage: "gearshape") { app.selectDesktop(.settings) }
                } label: {
                    HStack(spacing: 6) { Text("Mindwire").font(.headline); Image(systemName: "chevron.down").font(.caption2) }
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 18) {
            TextField("Ask Mindwire to do anything…", text: $draft.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(3...8)
                .focused($focused)
                .disabled(creating)
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift), hasText, !creating else { return .ignored }
                    startChat()
                    return .handled
                }
                .accessibilityIdentifier("desktop.composer")
            if let error {
                ChatErrorDisclosure(detail: error) { self.error = nil }
            }
            HStack(spacing: 16) {
                contextMenu
                Spacer(minLength: 0)
                if creating {
                    ProgressView().controlSize(.small).frame(width: 36, height: 36)
                } else {
                    Button(action: startChat) {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(hasText ? (colorScheme == .dark ? Color.black : .white) : .secondary)
                            .frame(width: 36, height: 36)
                            .background(hasText ? (colorScheme == .dark ? Color.white : .black) : Color.primary.opacity(0.06), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasText)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("desktop.send")
                }
            }
        }
        .padding(22)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var contextMenu: some View {
        let selectedProjectID = project?.id
        let selectedAgentID = agent?.id
        return Menu {
            Section("Work on") {
                ForEach(projects) { project in
                    Button {
                        projectID = project.id
                        agentID = ""
                    } label: {
                        Label(project.name, systemImage: selectedProjectID == project.id ? "checkmark" : "folder")
                    }
                }
            }
            if !agents.isEmpty {
                Section("Connected subscription") {
                    ForEach(agents) { agent in
                        Button { agentID = agent.id } label: {
                            Label(agent.displayName, systemImage: selectedAgentID == agent.id ? "checkmark" : "sparkles")
                        }
                    }
                }
            }
            Button("Connect a computer…", systemImage: "plus") { pairing = true }
            Button("Manage computers…", systemImage: "desktopcomputer") { app.selectDesktop(.workspaces) }
        } label: {
            Label(project?.name ?? "Connect a computer", systemImage: "desktopcomputer")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .buttonStyle(.plain)
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

    private var suggestions: some View {
        HStack(spacing: 12) {
            suggestion("Build something", symbol: "hammer", text: "Help me build ")
            suggestion("Organize my files", symbol: "folder", text: "Help me organize ")
            suggestion("Automate a task", symbol: "sparkles", text: "Help me automate ")
        }
        .buttonStyle(.plain)
        .disabled(creating)
    }

    private func suggestion(_ title: String, symbol: String, text: String) -> some View {
        Button { draft.text = text; focused = true } label: {
            Label(title, systemImage: symbol).font(.callout).padding(.horizontal, 16).padding(.vertical, 11)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
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
