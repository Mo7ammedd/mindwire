import SwiftUI

/// Each credential method has a dedicated native form. The Oblien GitHub App
/// retains its OAuth/install flow, independent of personal tokens and SSH keys.
struct GitHubConnectScreen: View {
    var workspaceId: String?
    var onConnected: (GitHubAccount) -> Void
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var connectError: String?
    @State private var ghStatus: GitHubStatus?
    @State private var loadingStatus = false
    @State private var showLogin = false
    @State private var appSafari: IdentifiedURL?
    @State private var pendingStep: GHStep?
    private enum GHStep { case connect, install }
    private var ghSupported: Bool { workspaceId.map { stores.workspaceSupportsGh($0) } ?? false }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    credentialLink(.token)
                    credentialLink(.sshKey)
                    if ghSupported {
                        Button { connectGh() } label: {
                            Label(t("github.connect.gh.title"), icon: Icon.terminal)
                        }
                        .tint(.primary)
                    }
                } header: { Text(t("github.credential.addConnection")) }
                if ghStatus?.available != false { appSection }
                if let connectError {
                    Section { Text(connectError).foregroundStyle(.red).font(.footnote) }
                }
            }
            .disabled(connecting)
            .navigationTitle(t("github.connect.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.tint(.primary)
                }
                if connecting { AppToolbarItem(placement: .topBarTrailing) { ProgressView().controlSize(.small) } }
            }
            .sheet(item: $appSafari, onDismiss: { Task { await onAppSafariDone() } }) { item in
                SafariView(url: item.url) { appSafari = nil }.ignoresSafeArea()
            }
            .sheet(isPresented: $showLogin) {
                MindwireLoginSheet {
                    if let step = pendingStep { pendingStep = nil; openStep(step) }
                    else { Task { await loadGitHubStatus() } }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .oblienGitHubConnected)) { _ in
                if appSafari != nil { appSafari = nil } else { Task { await onAppSafariDone() } }
            }
            .task { await loadGitHubStatus() }
        }
    }

    private func credentialLink(_ mode: GitHubAuthMode) -> some View {
        NavigationLink {
            GitHubCredentialEditor(mode: mode, onSaved: finish)
        } label: {
            Label { Text(mode.title) } icon: { GitHubCredentialIcon(mode: mode) }
        }
    }

    private var appSection: some View {
        Section {
            if loadingStatus {
                ProgressView().controlSize(.small)
            } else if ghStatus?.connected == true {
                LabeledContent(t("github.accounts.connected"), value: ghStatus?.login ?? "")
                githubButton(t("github.connect.install.cta")) { openStep(.install) }
            } else {
                githubButton(t("github.connect.connect.cta")) { openStep(.connect) }
            }
        } header: { Text(t("github.connect.oblienApp.title")) }
          footer: { Text(t("github.credential.oblienHint")) }
    }

    private func githubButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { ProviderLogo(id: .github, size: 22) }
        }
        .tint(.primary)
    }

    private func openStep(_ step: GHStep) {
        guard !connecting else { return }
        connecting = true
        connectError = nil
        Task { @MainActor in
            defer { connecting = false }
            do {
                guard await MindwireAuth.shared.ensure() else {
                    pendingStep = step
                    showLogin = true
                    return
                }
                let api = GitHubConnectAPI()
                let url = step == .connect ? try await api.connectURL() : try await api.installURL()
                pendingStep = step
                appSafari = IdentifiedURL(url: url)
            } catch { connectError = error.localizedDescription }
        }
    }

    private func onAppSafariDone() async {
        let step = pendingStep
        pendingStep = nil
        do {
            let status = try await GitHubConnectAPI().status()
            ghStatus = status
            if step == .install, status.connected, let login = status.login {
                let account = stores.gitHubAccounts().first { $0.mode == .oblienApp && $0.login == login }
                    ?? stores.connectOblienApp(login: login, name: nil, avatarUrl: status.avatarUrl)
                finish(account)
            }
        } catch { connectError = error.localizedDescription }
    }

    private func loadGitHubStatus() async {
        guard MindwireAuth.shared.authenticated else { return }
        loadingStatus = true
        defer { loadingStatus = false }
        do { ghStatus = try await GitHubConnectAPI().status() }
        catch { connectError = error.localizedDescription }
    }

    private func connectGh() {
        guard let workspaceId, !connecting else { return }
        connecting = true
        connectError = nil
        Task { @MainActor in
            defer { connecting = false }
            do {
                let user = try await GhCliGitHubService(stores: stores).identity(workspaceId: workspaceId)
                finish(stores.connectGh(workspaceId: workspaceId, login: user.login))
            } catch { connectError = error.localizedDescription }
        }
    }

    private func finish(_ account: GitHubAccount) {
        dismiss()
        onConnected(account)
    }
}
