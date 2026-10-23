import Foundation

/// Keep a native harness's loopback callback reachable while in-app Safari is
/// open. The authorization URL and redirect stay exactly as issued by the CLI;
/// OAuth state, PKCE, token exchange and storage remain entirely with the CLI.
@MainActor
final class NativeLoginBrowser {
    private var forward: ConnectionPortForward?
    private var ssh: SSHConnection?
    private var listener: SSHLocalForwarder?
    private var closed = false

    static func callback(_ url: URL) -> URL? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "redirect_uri" })?.value,
              let callback = URL(string: value), callback.scheme == "http",
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(callback.host?.lowercased() ?? ""),
              let port = callback.port, (1024...65535).contains(port),
              callback.user == nil, callback.password == nil else { return nil }
        return callback
    }

    func prepare(url: URL, workspace: Workspace, stores: Stores) async throws {
        guard let callback = Self.callback(url), let port = callback.port else { return }
        guard !closed else { throw CancellationError() }
        if workspace.runtime.isLocal, ApplePlatform.isDesktop { return }
        do {
            if workspace.runtime.sandbox == nil, let id = workspace.runtime.serverId,
               let connection = stores.connections.get(id) {
                let forward = ConnectionPortForward(connection: connection, port: port, stores: stores,
                    localPort: port, id: "auth-\(UUID().uuidString)")
                self.forward = forward
                let bound = try await forward.ready()
                guard bound == port else {
                    throw BackendError.message("Another connection is using the sign-in port. Close it and try again.")
                }
            } else if let cloudID = workspace.runtime.workspaceId {
                let ssh = try await SSHConnection.cloud(workspaceId: cloudID)
                if closed || Task.isCancelled { ssh.close(); throw CancellationError() }
                self.ssh = ssh
                let listener = try await ssh.forwardLocal(host: "127.0.0.1", port: port, localPort: port)
                if closed || Task.isCancelled { listener.close(); throw CancellationError() }
                self.listener = listener
            } else {
                throw BackendError.message("Browser sign-in needs a private connection to this computer.")
            }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        closed = true
        forward?.stop(); forward = nil
        listener?.close(); listener = nil
        ssh?.close(); ssh = nil
    }
}
