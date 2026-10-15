import SwiftUI

/// One binding editor for a workspace default or a project's override.
struct GitAccessSettingsScreen: View {
    let workspaceId: String
    var projectId: String? = nil
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [GitHubAccount] = []
    @State private var selectedID = ""
    @State private var lifetime: GitCredentialLifetime = .run
    @State private var original: GitConnection?
    @State private var storedIDs: [String] = []
    @State private var savedConnections: [GitConnection] = []
    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var showConnect = false
    @State private var confirmForget = false

    private var service: WorkspaceGitService { .init(workspaceId: workspaceId, stores: stores) }
    private var connection: GitConnection? {
        if selectedID.isEmpty { return nil }
        if selectedID == "native" { return .server }
        if let account = accounts.first(where: { $0.id == selectedID }) { return .init(account: account, lifetime: lifetime) }
        guard var selected = original?.id == selectedID ? original : savedConnections.first(where: { $0.id == selectedID }) else { return nil }
        selected.lifetime = lifetime
        return selected
    }

    var body: some View {
        Form {
            if loaded {
                Section {
                    Picker(t("github.accounts.connection"), selection: $selectedID) {
                        Text(t(projectId == nil ? "github.access.noDefault" : "github.access.inherit")).tag("")
                        Text(t("github.access.server")).tag("native")
                        ForEach(accounts) { Text($0.connectionLabel).tag($0.id) }
                        if let original, original.mode != "native", !accounts.contains(where: { $0.id == original.id }) {
                            Text(original.label).tag(original.id)
                        }
                        ForEach(savedConnections.filter { saved in
                            saved.id != original?.id && !accounts.contains(where: { $0.id == saved.id })
                        }) { Text($0.label).tag($0.id) }
                    }
                    Button { showConnect = true } label: {
                        Label(t("github.credential.addConnection"), icon: Icon.plus)
                    }
                    .tint(.primary)
                    if let account = accounts.first(where: { $0.id == selectedID }) {
                        NavigationLink(t("github.credential.manageConnection")) {
                            GitHubConnectionScreen(account: account)
                        }
                    } else {
                        NavigationLink(t("github.credential.manageConnections")) { GitHubAccountsScreen() }
                    }
                }
                if let connection {
                    Section {
                        if !connection.usesServerCredentials && !connection.readOnly {
                            Picker(t("github.access.availability"), selection: $lifetime) {
                                ForEach(GitCredentialLifetime.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        }
                    } footer: {
                        Text(connection.readOnly ? t("github.access.oblienReadOnly")
                             : connection.usesServerCredentials ? t("github.access.serverHint")
                             : lifetime == .workspace ? t("github.access.workspaceHint") : t("github.access.runHint"))
                    }
                    if storedIDs.contains(connection.id) {
                        Section {
                            Button(t("github.access.forget"), role: .destructive) { confirmForget = true }
                        }
                    }
                }
            } else if error == nil {
                ProgressView()
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    if !loaded { Button(t("common.retry")) { Task { await load() } } }
                }
            }
            if let workspace = WorkspaceRepository.shared.get(workspaceId) {
                WorkspaceDaemonSection(workspace: workspace)
            }
        }
        .serviceUpdatePresentation()
        .navigationTitle(t("github.access.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppToolbarItem(placement: .confirmationAction) {
                Button(t("common.save")) { Task { await save() } }.disabled(!loaded || working).tint(.primary)
            }
        }
        .disabled(working)
        .task { if !loaded { await load() } else { reloadAccounts() } }
        .onReceive(NotificationCenter.default.publisher(for: .gitHubAccountsChanged, object: stores)) { _ in reloadAccounts() }
        .onChange(of: selectedID) { _, _ in
            if selectedID == original?.id { lifetime = original?.lifetime ?? .run }
            else { lifetime = !accounts.contains(where: { $0.id == selectedID }) && storedIDs.contains(selectedID) ? .workspace : .run }
        }
        .sheet(isPresented: $showConnect) {
            GitHubConnectScreen(workspaceId: workspaceId) { account in
                reloadAccounts()
                selectedID = account.id
            }
        }
        .alert(t("github.access.forget"), isPresented: $confirmForget) {
            Button(t("github.access.forget"), role: .destructive) { Task { await forget() } }
            Button(t("common.cancel"), role: .cancel) {}
        } message: { Text(t("github.access.forgetHint")) }
    }

    private func reloadAccounts() {
        accounts = stores.gitHubAccounts().filter { $0.mode != .ghCli || $0.workspaceId == workspaceId }
    }

    private func load() async {
        reloadAccounts()
        error = nil
        do {
            let state = try await service.state()
            storedIDs = state.storedConnectionIds
            savedConnections = state.storedConnections ?? []
            if let projectId {
                let project = try await service.projectState(projectId)
                original = project.inherited ? nil : project.connection
            } else { original = state.default }
            selectedID = original?.id ?? ""
            lifetime = original?.lifetime ?? .run
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard !working else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let value = connection
            // An explicit Save refreshes a workspace copy from this device when
            // available. A second device can retain an existing server credential.
            let stored = value.map { storedIDs.contains($0.id) && !accounts.contains(where: { $0.id == selectedID }) } ?? false
            if let projectId {
                guard let project = stores.projects.get(projectId) else { throw WorkspaceRegistryError.missing }
                try await service.setProject(project, connection: value, stored: stored)
            } else { try await service.setDefault(value, stored: stored) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func forget() async {
        guard let connection, !working else { return }
        working = true
        defer { working = false }
        do {
            try await service.forget(connection.id)
            storedIDs.removeAll { $0 == connection.id }
            savedConnections.removeAll { $0.id == connection.id }
        } catch { self.error = error.localizedDescription }
    }
}
