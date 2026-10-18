import SwiftUI

/// The same computer-owned profiles and auth screens used during setup. Opening
/// management never selects a different assistant or starts a login attempt.
struct AssistantAIConnectionsScreen: View {
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @State private var selectedWorkspaceID: String?
    @State private var discovery = AssistantConnectionDiscovery()
    @State private var showingSetup = false

    init(workspaceID: String? = nil) {
        _selectedWorkspaceID = State(initialValue: workspaceID)
    }

    private var workspace: Workspace? {
        if let id = selectedWorkspaceID, let workspace = repository.get(id) { return workspace }
        if let id = stores.experience.assistantAgentID.flatMap(stores.agents.get)?.workspaceId,
           let workspace = repository.get(id) { return workspace }
        return repository.all.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let workspace {
                if repository.all.count > 1 {
                    Picker("Computer", selection: Binding(
                        get: { workspace.id }, set: { selectedWorkspaceID = $0 }
                    )) {
                        ForEach(repository.all) { computer in
                            Text(computer.runtime.isLocal ? "This Mac" : computer.name).tag(computer.id)
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 16)
                }
                AssistantConnectionPicker(workspace: workspace, repository: repository, discovery: discovery,
                                          managesConnections: true, onReady: { _ in })
                    .id(workspace.id)
            } else {
                ContentUnavailableView {
                    Label("Connect a computer", systemImage: "laptopcomputer")
                } description: {
                    Text("Your AI connections stay on your computer.")
                } actions: {
                    Button("Add computer") { showingSetup = true }.tint(.primary)
                }
            }
        }
        .background(AssistantStyle.canvas)
        .navigationTitle("AI connections")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSetup) {
            AssistantSetupScreen(repository: repository) { showingSetup = false }
        }
        .task { await repository.refreshIfNeeded() }
    }
}
