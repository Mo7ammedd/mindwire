import SwiftUI

/// Reachability is checked from the master, so phone connectivity is never mistaken for a
/// working link between the computers. Rechecks are explicit or tied to connection changes.
struct BotConnectionsScreen: View {
    var repository: WorkspaceRepository = .shared
    var embedded = false
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if embedded { connectionList }
        else {
            NavigationStack {
                connectionList
                    .toolbar { AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { dismiss() } } }
            }
        }
    }

    private var connectionList: some View {
        let connections = stores.workspaceData.botConnections
        return List {
            if connections.pendingRevocations > 0 {
                Section {
                    Label(t("bots.connections.revoking"), systemImage: "clock")
                    Text(t("bots.connections.revokingBody")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(repository.all) { workspace in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            AppIcon(workspace.isCloud ? .cloud : .laptop, size: 22, decorative: true)
                            Text(workspace.name).font(.body.weight(.medium))
                            Spacer()
                            if connections.syncing { ProgressView().controlSize(.small) }
                            else if connections.outgoingOnly.contains(workspace.id) {
                                Text(t("bots.connections.outgoingOnly")).font(.caption).foregroundStyle(.secondary)
                            }
                            else if connections.configured.contains(workspace.id) {
                                Text(t("bots.connections.linked")).font(.caption).foregroundStyle(.secondary)
                            } else if workspace.id == connections.masterWorkspaceID {
                                Text("Mindwire").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let issue = connections.issues[workspace.id] {
                            Text(issue).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } footer: {
                Text(t("bots.connections.help"))
            }
            Section {
                Button(t("common.retry")) { connections.schedule(repository.all, force: true) }
                    .disabled(connections.syncing)
            }
        }
        .navigationTitle(t("bots.connections.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
