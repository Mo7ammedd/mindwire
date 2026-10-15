import Foundation

@MainActor
protocol WorkspaceDesktopProvider: AnyObject {
    var usesLocalSetup: Bool { get }
    func status() async throws -> DesktopProviderStatus
    func authorize(api: DaemonHTTP, status: DesktopProviderStatus, resuming: Bool) async throws -> DesktopSnapshot
    func openDisplay(api: DaemonHTTP, session: DesktopSession) async throws -> DesktopDisplayConnection
    func credentials() async throws -> DesktopLoginCredentials
    func prepareSession() async throws
}

extension WorkspaceDesktopProvider {
    var usesLocalSetup: Bool { false }
    func credentials() async throws -> DesktopLoginCredentials {
        throw DesktopProblem(code: "unsupported", message: "Manage desktop access in the Mindwire CLI on your Mac.")
    }
    func prepareSession() async throws {}
}

@MainActor
final class DesktopDisplayConnection {
    let port: Int
    private var cleanup: (() -> Void)?
    init(port: Int, cleanup: @escaping () -> Void) { self.port = port; self.cleanup = cleanup }
    func close() { let action = cleanup; cleanup = nil; action?() }
}

@MainActor
enum WorkspaceDesktopProviders {
    static func computerConnection(_ workspace: Workspace, stores: Stores) -> Connection? {
        guard workspace.runtime.sandbox == nil, let id = workspace.runtime.serverId,
              let connection = stores.connections.get(id), let computer = connection.pairedComputer,
              computer.operatingSystem == "darwin" else { return nil }
        return connection
    }
    static func supports(_ workspace: Workspace, stores: Stores) -> Bool {
        workspace.isCloud || computerConnection(workspace, stores: stores) != nil
    }
    static func make(_ workspace: Workspace, stores: Stores, desktopId: String? = nil) -> any WorkspaceDesktopProvider {
        if workspace.isCloud { return CloudDesktopProvider(workspaceId: workspace.id, desktopId: desktopId) }
        if let connection = computerConnection(workspace, stores: stores) {
            return ComputerDesktopProvider(workspace: workspace, connection: connection, stores: stores,
                                           api: { try await stores.workspaceData.desktopHTTP(workspace) })
        }
        return UnavailableDesktopProvider()
    }
}

@MainActor
private final class UnavailableDesktopProvider: WorkspaceDesktopProvider {
    func status() async throws -> DesktopProviderStatus { .init(supported: false, enabled: false, available: false, credentials: false) }
    func authorize(api: DaemonHTTP, status: DesktopProviderStatus, resuming: Bool) async throws -> DesktopSnapshot {
        throw DesktopProblem(code: "unsupported", message: "This workspace does not provide a desktop.")
    }
    func openDisplay(api: DaemonHTTP, session: DesktopSession) async throws -> DesktopDisplayConnection {
        throw DesktopProblem(code: "unsupported", message: "This workspace does not provide a desktop.")
    }
}

extension CloudDesktopProvider: WorkspaceDesktopProvider {
    func authorize(api: DaemonHTTP, status: DesktopProviderStatus, resuming: Bool) async throws -> DesktopSnapshot {
        if !status.enabled {
            guard !resuming else { throw DesktopProblem(code: "desktop_disabled", message: "Desktop access was turned off. Connect to enable it again.") }
            try await enable()
        }
        try Task.checkCancellation()
        try await prepareSavedDesktop(resuming: resuming)
        let grant = try await connection()
        let token = try await gatewayToken()
        let registry: WorkspaceMetadata = try await api.decode("GET", "/workspace", quiet: true)
        try Task.checkCancellation()
        var binding: [String: Any] = ["registryId": registry.workspaceId, "workspaceId": workspaceId,
            "gatewayToken": token, "connection": try grant.desktopJSON()]
        if let desktopId { binding["desktopId"] = desktopId }
        return try await api.decode("PUT", "/surfaces/desktop/binding", json: binding, quiet: true)
    }

    func openDisplay(api: DaemonHTTP, session: DesktopSession) async throws -> DesktopDisplayConnection {
        guard desktopId == nil || session.desktopId == desktopId else {
            throw DesktopProblem(code: "session_mismatch", message: "The desktop selection changed. Reopen this desktop.")
        }
        let grant = try await connection()
        let ssh = SSHConnection(host: grant.ssh.host, port: grant.ssh.port, username: grant.ssh.username,
            auth: .password(grant.ssh.password), expectedHostKey: grant.ssh.host_key_fingerprint)
        do {
            let forward = try await ssh.forwardLocal(host: grant.vnc.host, port: grant.vnc.port)
            if Task.isCancelled { forward.close(); throw CancellationError() }
            return DesktopDisplayConnection(port: forward.port) { forward.close(); ssh.close() }
        } catch { ssh.close(); throw error }
    }
}

@MainActor
final class ComputerDesktopProvider: WorkspaceDesktopProvider {
    static let viewerPort = 8794
    let usesLocalSetup = true
    private let workspace: Workspace
    private let connection: Connection
    private let stores: Stores
    private let api: () async throws -> DaemonHTTP
    private var current: DesktopSnapshot?

    init(workspace: Workspace, connection: Connection, stores: Stores,
         api: @escaping () async throws -> DaemonHTTP) {
        self.workspace = workspace; self.connection = connection; self.stores = stores; self.api = api
    }
    func status() async throws -> DesktopProviderStatus {
        let http = try await api()
        let value: DesktopSnapshot = try await http.decode("GET", "/surfaces/desktop?refresh=true", quiet: true)
        try Task.checkCancellation()
        current = value
        return .init(supported: value.supported, enabled: value.enabled, available: value.available,
                     credentials: false, setup: value.setup)
    }
    func authorize(api: DaemonHTTP, status: DesktopProviderStatus, resuming: Bool) async throws -> DesktopSnapshot {
        guard let current, current.provider == "macos" else {
            throw DesktopProblem(code: "update_required", message: "Update Mindwire on this Mac to use desktop control.")
        }
        guard current.enabled, current.setup == nil else {
            throw DesktopProblem(code: "desktop_setup_required", message: "Run mindwire desktop enable on your Mac to allow desktop access.")
        }
        return current
    }
    func openDisplay(api: DaemonHTTP, session: DesktopSession) async throws -> DesktopDisplayConnection {
        let forward = ConnectionPortForward(connection: connection, port: Self.viewerPort, stores: stores, desktopSessionId: session.id)
        do {
            let port = try await forward.ready()
            try Task.checkCancellation()
            return DesktopDisplayConnection(port: port) { forward.stop() }
        } catch { forward.stop(); throw error }
    }
}
