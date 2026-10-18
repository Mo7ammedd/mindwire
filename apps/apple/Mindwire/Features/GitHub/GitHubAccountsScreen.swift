import SwiftUI

/// Named credentials and the optional Oblien GitHub App integration.
struct GitHubAccountsScreen: View {
    @Environment(\.stores) private var stores
    @State private var authed: Bool?
    @State private var showLogin = false
    @State private var showConnect = false
    @State private var ghStatus: GitHubStatus?
    @State private var installs: [GitHubOwner] = []
    @State private var loadingInstalls = false
    @State private var accounts: [GitHubAccount] = []
    @State private var account: GitHubAccount?     // local Oblien-App record (for browsing repos)
    @State private var appSafari: IdentifiedURL?
    @State private var error: String?
    @State private var pendingRemoval: GitHubAccount?
    @State private var confirmDisconnect = false
    @State private var pendingStep: GHStep?
    @State private var didLoad = false
    @State private var working = false

    private enum GHStep { case connect, install }
    private var otherAccounts: [GitHubAccount] { accounts.filter { $0.mode != .oblienApp } }

    var body: some View {
        content
        .navigationTitle(t("github.accounts.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { guard !didLoad else { return }; didLoad = true; await reload() }
        .onAppear { accounts = stores.gitHubAccounts() }
        .refreshable { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .gitHubAccountsChanged, object: stores)) { _ in
            accounts = stores.gitHubAccounts()
        }
        .sheet(isPresented: $showLogin) {
            MindwireLoginSheet {
                authed = true
                if let step = pendingStep { pendingStep = nil; startStep(step) }
                else { Task { await reload() } }
            }
        }
        .sheet(isPresented: $showConnect) {
            GitHubConnectScreen(workspaceId: nil) { added in
                accounts = stores.gitHubAccounts()
                if added.mode == .oblienApp { Task { await reload() } }
            }
        }
        .sheet(item: $appSafari, onDismiss: { Task { await reload() } }) { item in
            SafariView(url: item.url) { appSafari = nil }.ignoresSafeArea()
        }
        .onReceive(NotificationCenter.default.publisher(for: .oblienGitHubConnected)) { _ in
            if appSafari != nil { appSafari = nil } else { Task { await reload() } }
        }
        .alert(t("github.credential.removeTitle", ["name": pendingRemoval?.displayName ?? ""]), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { account in
            Button(t("common.cancel"), role: .cancel) {}
            Button(t("github.accounts.removeLocal"), role: .destructive) { remove(account) }
        } message: { _ in Text(t("github.credential.removeHint")) }
        .alert(t("github.accounts.disconnect"), isPresented: $confirmDisconnect) {
            Button(t("common.cancel"), role: .cancel) {}
            Button(t("github.accounts.disconnect"), role: .destructive) { disconnectApp() }
        } message: { Text(t("github.credential.disconnectHint")) }
    }

    private var content: some View {
        List {
            connectionsSection
            if ghStatus?.available != false { appSection }
            if ghStatus?.connected == true { installationsSection }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
    }

    // MARK: Oblien GitHub App

    private var appSection: some View {
        Section {
            if authed == true && ghStatus == nil {
                statusRow(t("github.accounts.checking"))
            } else if ghStatus?.connected == true {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("github.accounts.connected"))
                        if let login = ghStatus?.login, !login.isEmpty {
                            Text(login).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    AppIcon(Icon.checkmark).foregroundStyle(.secondary)
                }
                DestructiveButton(t("github.accounts.disconnect"), icon: Icon.trash) {
                    confirmDisconnect = true
                }
            } else {
                Button { startStep(.connect) } label: {
                    Label { Text(t("github.connect.connect.cta")) } icon: { ProviderLogo(id: .github, size: 20) }
                }
                .tint(.primary)
            }
        } header: {
            Text(t("github.connect.oblienApp.title"))
        } footer: {
            if ghStatus?.connected != true { Text(t("github.credential.oblienHint")) }
        }
        .disabled(working)
    }

    private var installationsSection: some View {
        Section {
            if loadingInstalls && installs.isEmpty {
                statusRow(t("github.accounts.loadingInstallations"))
            } else if installs.isEmpty {
                Text(t("github.accounts.noInstallations")).font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(installs) { installRow($0) }
            }
            Button { startStep(.install) } label: {
                Label(t("github.connect.install.cta"), icon: Icon.plus)
            }
            .tint(.primary)
        } header: {
            Text(t("github.accounts.installations"))
        }
    }

    // MARK: Connections

    private var connectionsSection: some View {
        Section {
            ForEach(otherAccounts) { acct in
                NavigationLink {
                    GitHubConnectionScreen(account: acct)
                } label: {
                    GitHubConnectionRow(account: acct)
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingRemoval = acct } label: {
                        Label(t("github.accounts.removeLocal"), icon: Icon.trash)
                    }
                }
            }
            Button { showConnect = true } label: {
                Label(t("github.credential.addConnection"), icon: Icon.plus)
            }
            .tint(.primary)
        } header: {
            Text(t("github.credential.connections"))
        }
    }

    // MARK: Rows

    private func installRow(_ owner: GitHubOwner) -> some View {
        NavigationLink {
            if let account { GitHubRepoListScreen(account: account, owner: owner) }
        } label: {
            HStack(spacing: Spacing.md) {
                avatar(owner)
                VStack(alignment: .leading, spacing: 2) {
                    Text(owner.login).lineLimit(1)
                    Text(owner.kind == .org ? t("github.accounts.org") : t("github.accounts.user"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func avatar(_ owner: GitHubOwner) -> some View {
        Group {
            if let s = owner.avatarUrl, let url = URL(string: s) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { avatarFallback(owner) }
            } else {
                avatarFallback(owner)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }

    private func avatarFallback(_ owner: GitHubOwner) -> some View {
        AppIcon(owner.kind == .org ? .building : .userCircle)
            .resizable()
            .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func reload() async {
        accounts = stores.gitHubAccounts()
        error = nil
        authed = MindwireAuth.shared.authenticated
        guard authed == true else { ghStatus = nil; installs = []; return }
        do { ghStatus = try await GitHubConnectAPI().status() }
        catch { self.error = error.localizedDescription; return }
        if ghStatus?.connected == true {
            if !accounts.contains(where: { $0.mode == .oblienApp }), let login = ghStatus?.login {
                stores.connectOblienApp(login: login, name: nil, avatarUrl: ghStatus?.avatarUrl)
                accounts = stores.gitHubAccounts()
            }
            loadingInstalls = true
            installs = (try? await GitHubConnectAPI().installations()) ?? []
            loadingInstalls = false
        } else {
            installs = []
        }
        account = accounts.first { $0.mode == .oblienApp }
    }

    private func startStep(_ step: GHStep) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                guard await MindwireAuth.shared.ensure() else { pendingStep = step; showLogin = true; return }
                let api = GitHubConnectAPI()
                appSafari = IdentifiedURL(url: step == .connect ? try await api.connectURL() : try await api.installURL())
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func disconnectApp() {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await GitHubConnectAPI().disconnect()
                for a in stores.gitHubAccounts() where a.mode == .oblienApp { stores.removeGitHubAccount(a.id) }
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func remove(_ account: GitHubAccount) {
        if stores.removeGitHubAccount(account.id) { accounts = stores.gitHubAccounts() }
        else { error = t("github.credential.removeFailed") }
    }
}
