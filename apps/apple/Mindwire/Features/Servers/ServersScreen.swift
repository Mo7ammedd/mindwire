// One manager for paired personal computers and SSH hosts.
import SwiftUI

struct ServersScreen: View {
    @Environment(\.stores) private var stores
    @State private var servers: [Connection] = []
    @State private var adding: ConnectionAddDestination?

    var body: some View {
        List {
            if servers.isEmpty {
                Section {
                    Button { adding = .computer } label: { ConnectionDestinationRow(type: .local) }
                        .tint(.primary)
                }
                Section {
                    Button { adding = .server } label: { ConnectionDestinationRow(type: .ssh) }
                        .tint(.primary)
                } footer: {
                    Text("Manage your own computers and servers here. Oblien Cloud workspaces stay in Workspaces.")
                }
            } else {
                group("Computers", servers.filter(\.isLocal))
                group("SSH servers", servers.filter { !$0.isLocal })
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Computers & Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !servers.isEmpty {
                AppToolbarItem(placement: .topBarTrailing) {
                    Button("Add connection", icon: Icon.plus) { adding = .choose }
                        .tint(.primary)
                }
            }
        }
        .sheet(item: $adding, onDismiss: reload) { destination in
            AddServerScreen(presetType: destination.type) { _ in reload() }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder private func group(_ title: String, _ items: [Connection]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { server in
                    NavigationLink(value: SettingsRoute.serverDetail(id: server.id)) {
                        EntityRow {
                            Text(server.name)
                        } subtitle: {
                            Text(server.displayAddress)
                        } icon: {
                            ModeIcon(type: server.type, size: 22)
                        }
                    }
                }
            }
        }
    }

    private func reload() {
        servers = stores.connections.list()
    }

}
