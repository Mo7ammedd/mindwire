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
    @SceneStorage("mindwire.desktop.local-default") private var selectedLocalDefault = false
    @State private var creating = false
    @State private var error: String?
    @State private var computer = DesktopComputer.shared
    @AppStorage("mindwire.desktop.developerTools") private var developerTools = false
    @State private var projects: [Project] = []
    @State private var allAgents: [Agent] = []
    @FocusState private var focused: Bool
    private let draftKey = "desktop:new-chat"

    private var project: Project? { projects.first { $0.id == (projectID.isEmpty ? computer.projectId : projectID) } }
    private var agents: [Agent] { project.map { project in allAgents.filter { $0.workspaceId == project.workspaceId } } ?? [] }
    private var agent: Agent? { agentID.isEmpty ? agents.first : agents.first { $0.id == agentID } }
    private var hasText: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSubmit: Bool { hasText && !creating && !computer.preparing && project != nil }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 30) {
                    Spacer(minLength: 32)
                    Text("What can I help with?")
                        .font(.largeTitle.weight(.medium))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 16) {
                        composer
                        if let error = computer.error {
                            HStack(alignment: .top, spacing: 16) {
                                ChatErrorDisclosure(title: "Couldn't start on this Mac", detail: error)
                                Button("Try again") {
                                    Task { await computer.prepare(stores: stores, repository: repository) }
                                }
                                .buttonStyle(.borderless)
                            }
                        } else if !computer.preparing, agent == nil {
                            HStack(spacing: 6) {
                                Text("Bring your subscription.").foregroundStyle(.secondary)
                                Button("Set up Mindwire") { app.selectDesktop(.agents) }
                                    .buttonStyle(.borderless)
                            }
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    Spacer(minLength: 32)
                }
                .frame(maxWidth: ChatContentStyle.columnWidth)
                .padding(.horizontal, ChatContentStyle.horizontalInset)
                .padding(.bottom, geometry.size.height * 0.12)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Mindwire")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draft = stores.chatDrafts.draft(for: draftKey)
            reloadContext()
            focused = true
        }
        .onChange(of: stores.projects.revision) { reloadContext() }
        .onChange(of: stores.agents.revision) { reloadContext() }
        .onChange(of: repository.revision) { reloadContext() }
        .onChange(of: stores.workspaces.revision) { reloadContext() }
        .onDisappear { stores.chatDrafts.persist(draftKey) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stores.chatDrafts.persist(draftKey) } }
        .task { await computer.prepare(stores: stores, repository: repository) }
        .onChange(of: computer.projectId) { previous, current in
            if projectID.isEmpty || projectID == previous {
                projectID = current ?? ""
                agentID = ""
            }
            reloadContext()
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ChatComposer {
                TextField(t("chat.placeholder"), text: $draft.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .naturalChatDirection(draft.text)
                    .disabled(creating)
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift), canSubmit else { return .ignored }
                        startChat()
                        return .handled
                    }
                    .accessibilityLabel("Message Mindwire")
                    .accessibilityIdentifier("desktop.composer")
            } leading: {
                contextMenu
            } trailing: {
                HStack(spacing: 12) {
                    if computer.preparing {
                        ProgressView().controlSize(.small).frame(width: 34, height: 34)
                            .accessibilityLabel("Starting Mindwire")
                    } else if creating {
                        ProgressView().controlSize(.small).frame(width: 34, height: 34)
                    } else {
                        Button(action: startChat) {
                            AppIcon(Icon.send, size: 16)
                                .foregroundStyle(canSubmit ? (colorScheme == .dark ? Color.black : .white) : .secondary)
                                .frame(width: 34, height: 34)
                                .background(canSubmit ? (colorScheme == .dark ? Color.white : .black) : Color.primary.opacity(0.06), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityLabel("Send message")
                        .accessibilityIdentifier("desktop.send")
                        .help("Send message (Return)")
                    }
                }
            }
            if let error {
                ChatErrorDisclosure(detail: error) { self.error = nil }
            }
        }
    }

    private var contextMenu: some View {
        let selectedProjectID = project?.id
        let selectedAgentID = agent?.id
        return AppMenu {
            if developerTools {
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
            }
            if !agents.isEmpty {
                Section("Connected subscription") {
                    ForEach(agents) { agent in
                        Button { agentID = agent.id } label: {
                            Label(agent.displayName, icon: selectedAgentID == agent.id ? .check : .key)
                        }
                    }
                }
            }
            Button("Subscriptions…", icon: .key) { app.selectDesktop(.agents) }
            Button("Other computers…", icon: .monitor) { app.selectDesktop(.workspaces) }
        } label: {
            AppIcon(.sliders, size: 18)
            .foregroundStyle(.primary)
            .frame(width: 34, height: 34)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(creating)
        .accessibilityLabel("Choose where Mindwire works")
        .help(project?.workspaceId == computer.workspaceId ? "This Mac · Chat settings" : project?.name ?? "Chat settings")
    }

    private func reloadContext() {
        let workspaceIDs = Set(repository.all.map(\.id))
        projects = stores.projects.list().filter { workspaceIDs.contains($0.workspaceId) }
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
        allAgents = stores.agents.list()
        if let id = computer.projectId, !selectedLocalDefault || projectID.isEmpty {
            projectID = id
            agentID = ""
            selectedLocalDefault = true
        }
    }

    private func startChat() {
        guard hasText, !creating else { return }
        guard !computer.preparing else { return }
        guard let project else {
            Task { await computer.prepare(stores: stores, repository: repository) }
            return
        }
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
