import SwiftUI

/// The same saved link opens from the catalog and a chat card. Private apps reuse
/// the existing SSH forwarder; credentials and temporary local URLs are never saved.
struct AppShortcutBrowser: View {
    let shortcut: AppShortcut
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var url: URL?
    @State private var error: String?
    @State private var retry = 0
    @State private var forward: ConnectionPortForward?
    @State private var ssh: SSHConnection?
    @State private var listener: SSHLocalForwarder?
    @State private var sourceURL: URL?
    @State private var opening = false
    @State private var attempt: UUID?
    @State private var connectionRevision = 0
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if let url, error == nil {
                    ForwardedWebPreview(url: forwardedURL ?? url, connectionRevision: forward?.connectionRevision ?? (retry + connectionRevision))
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn’t open \(shortcut.name)", systemImage: "app.dashed")
                    } description: { Text(error) } actions: {
                        Button("Try again") { retry += 1 }.buttonStyle(.bordered)
                    }
                } else {
                    VStack(spacing: 18) {
                        AppShortcutIcon(shortcut: shortcut, size: 64)
                        ProgressView("Opening \(shortcut.name)…").chatActivityTint()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay { if opening && url != nil { ProgressView().chatActivityTint().padding(14).background(.regularMaterial, in: .circle) } }
            .navigationTitle(shortcut.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.tint(.primary) }
                AppToolbarItem(placement: .topBarTrailing) {
                    Button { retry += 1 } label: { Image(systemName: "arrow.clockwise") }.tint(.primary)
                        .accessibilityLabel("Reload app")
                    Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }.tint(.primary)
                        .accessibilityLabel("App settings")
                }
            }
        }
        .task(id: "\(retry):\(scenePhase == .background)") {
            guard scenePhase != .background else { return }
            await open()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { attempt = nil; opening = false; closeTunnel() }
        }
        .onDisappear { attempt = nil; opening = false; closeTunnel() }
        .sheet(isPresented: $showingSettings) { AppShortcutSettings(shortcut: shortcut) }
        .frame(minWidth: ApplePlatform.isDesktop ? 680 : nil, minHeight: ApplePlatform.isDesktop ? 480 : nil)
    }

    private var forwardedURL: URL? {
        guard let base = forward?.url, let sourceURL, var destination = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else { return nil }
        destination.host = base.host; destination.port = base.port
        return destination.url
    }

    private func closeTunnel() { listener?.close(); listener = nil; ssh?.close(); ssh = nil; forward = nil }

    private func open() async {
        let currentAttempt = UUID()
        attempt = currentAttempt
        opening = true
        defer { if attempt == currentAttempt { opening = false } }
        closeTunnel()
        error = nil
        do {
            var current = stores.apps.get(shortcut.id) ?? shortcut
            guard !current.archived else { throw BackendError.message("This app was removed from Apps.") }
            if current.needsComputer { current = try await stores.workspaceData.openApp(current) }
            try Task.checkCancellation()
            guard attempt == currentAttempt else { return }
            guard let target = current.destination else { throw BackendError.message("This app’s link is invalid.") }
            sourceURL = target
            if !current.isLocalLink { url = target; return }
            guard let workspace = WorkspaceRepository.shared.get(shortcut.workspaceId) else { throw WorkspaceRegistryError.missing }
            let port = target.port ?? (target.scheme == "https" ? 443 : 80)
            var destination = URLComponents(url: target, resolvingAgainstBaseURL: false)!
            if workspace.runtime.isLocal {
                url = target
            } else if workspace.runtime.sandbox == nil, let id = workspace.runtime.serverId,
                      let connection = stores.connections.get(id) {
                let session = stores.portForwards.open(connection: connection, port: port)
                destination.host = "127.0.0.1"; destination.port = try await session.ready()
                try Task.checkCancellation()
                guard attempt == currentAttempt else { return }
                forward = session
                url = destination.url
            } else if let cloudID = workspace.runtime.workspaceId {
                let grant = try await MindwireCloud.workspace(cloudID).ssh.connection()
                try Task.checkCancellation()
                guard attempt == currentAttempt else { return }
                guard !grant.ssh.host.isEmpty, !grant.ssh.username.isEmpty, !grant.ssh.password.isEmpty,
                      (1...65535).contains(grant.ssh.port), grant.ssh.hostKeyFingerprint.hasPrefix("SHA256:") else {
                    throw BackendError.message("This computer did not provide a valid private connection.")
                }
                let connection = SSHConnection(host: grant.ssh.host, port: grant.ssh.port, username: grant.ssh.username,
                    auth: .password(grant.ssh.password), expectedHostKey: grant.ssh.hostKeyFingerprint)
                let opened: SSHLocalForwarder
                do { opened = try await connection.forwardLocal(host: "127.0.0.1", port: port) }
                catch { connection.close(); throw error }
                if Task.isCancelled || attempt != currentAttempt { opened.close(); connection.close(); throw CancellationError() }
                ssh = connection
                listener = opened
                connectionRevision += 1
                destination.host = "127.0.0.1"; destination.port = opened.port
                url = destination.url
            } else {
                throw BackendError.message("Ask the app’s bot to save a reachable link for this computer.")
            }
        } catch {
            guard attempt == currentAttempt else { return }
            closeTunnel()
            if !error.isRequestCancellation { self.error = error.localizedDescription }
        }
    }
}
