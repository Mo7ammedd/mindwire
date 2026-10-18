import SwiftUI

/// The desktop already owns its computer. This only connects an AI account, using the same
/// profiles, installation queue and authentication screens as every other entry point.
struct AssistantDesktopSetup: View {
    let workspace: Workspace
    let repository: WorkspaceRepository
    let onReady: (Agent, Project) -> Void
    @Environment(\.stores) private var stores
    @State private var connections = AssistantConnectionDiscovery()
    @State private var selectedAgent: Agent?
    @State private var readyAgent: Agent?
    @State private var preparationError: String?
    @State private var attempt = 0
    @State private var completed = false

    init(workspace: Workspace, repository: WorkspaceRepository? = nil, initialAgent: Agent? = nil,
         onReady: @escaping (Agent, Project) -> Void) {
        self.workspace = workspace
        self.repository = repository ?? .shared
        self.onReady = onReady
        _selectedAgent = State(initialValue: initialAgent?.workspaceId == workspace.id ? initialAgent : nil)
    }

    var body: some View {
        Group {
            if let readyAgent {
                preparation(readyAgent)
            } else if let selectedAgent {
                AgentSetupScreen(agent: selectedAgent, onRemoved: reset) {
                    readyAgent = selectedAgent
                }
                .id(selectedAgent.id)
                .overlay(alignment: .topLeading) {
                    Button(action: reset) {
                        Label(t("common.back"), systemImage: "chevron.left")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(AssistantDesktopStyle.surface, in: .capsule)
                    }
                    .buttonStyle(.plain).padding(24)
                }
            } else {
                AssistantConnectionPicker(workspace: workspace, repository: repository, discovery: connections) { agent in
                    guard agent.workspaceId == workspace.id else { return }
                    select(agent)
                    readyAgent = agent
                }
                    .id(workspace.id)
            }
        }
        .environment(\.appExperienceMode, .general)
        .background(AssistantDesktopStyle.canvas)
    }

    private func preparation(_ agent: Agent) -> some View {
        AssistantDesktopSetupPanel {
            AssistantBotAvatar(botId: "mindwire", size: 72)
            Text(t("assistant.setup.preparing")).font(.title2.weight(.semibold))
            if let preparationError {
                Text(preparationError).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(t("common.retry")) { attempt += 1 }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: "\(agent.id):\(attempt)") {
            guard !completed else { return }
            preparationError = nil
            do {
                let project = try await AssistantContext.prepare(agent: agent, stores: stores)
                try Task.checkCancellation()
                completed = true
                onReady(agent, project)
            } catch {
                if !error.isRequestCancellation { preparationError = error.localizedDescription }
            }
        }
    }

    private func select(_ agent: Agent) {
        guard agent.workspaceId == workspace.id else { return }
        stores.experience.pendingWorkspaceID = workspace.id
        stores.experience.pendingAgentID = agent.id
        selectedAgent = agent
    }

    private func reset() {
        selectedAgent = nil
        readyAgent = nil
        preparationError = nil
        stores.experience.pendingAgentID = nil
    }
}

/// A compact inline panel shared by account choice, authentication and installation progress.
/// The shell remains visible and no computer setup steps are introduced on the desktop.
struct AssistantDesktopSetupPanel<Content: View>: View {
    var maxWidth: CGFloat = 430
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24, content: content)
                    .frame(maxWidth: maxWidth)
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(AssistantDesktopStyle.canvas)
    }
}
