import SwiftUI

/// Organization remains instant offline. This on-demand detail makes its persistence
/// explicit without adding another checking banner to the project list.
struct ProjectLibrarySyncSheet: View {
    var workspaceId: String?
    let repository: WorkspaceRepository
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var retrying: Set<String> = []

    private var workspaces: [Workspace] {
        let ids = Set(stores.projectLibrary.savedWorkspaces + stores.projects.list().map(\.workspaceId))
        return ids.filter { workspaceId == nil || $0 == workspaceId }.compactMap(repository.get)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let library = stores.projectLibrary
        NavigationStack {
            List {
                Section {
                    if workspaces.isEmpty { Text(t("projects.library.local")).foregroundStyle(.secondary) }
                    ForEach(workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(workspace.name).font(.body.weight(.medium))
                                    Text(status(workspace.id)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if retrying.contains(workspace.id) {
                                    ProgressView().controlSize(.small)
                                } else if library.pendingWorkspaces.contains(workspace.id) || library.syncErrors[workspace.id] != nil {
                                    Button { retry(workspace) } label: { AppIcon(.refresh) }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel(t("workspace.sync.retry"))
                                }
                            }
                            if let error = library.syncErrors[workspace.id] {
                                Text(error).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: { Text(t("projects.library.body")) }
            }
            .navigationTitle(t("projects.library.sync"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func status(_ id: String) -> String {
        let library = stores.projectLibrary
        if library.syncErrors[id] != nil { return t("projects.library.attention") }
        if library.pendingWorkspaces.contains(id) { return t("projects.library.pending") }
        return t(library.isSaved(workspaceId: id) ? "projects.library.saved" : "projects.library.local")
    }

    private func retry(_ workspace: Workspace) {
        guard retrying.insert(workspace.id).inserted else { return }
        Task {
            defer { retrying.remove(workspace.id) }
            await stores.workspaceData.refresh(workspace)
            await stores.workspaceData.waitForProjectLibrarySync(workspaceId: workspace.id)
        }
    }
}
