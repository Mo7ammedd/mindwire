import Foundation

final class DockerWorkspaceBackend: Backend {
    let runtime: AgentRuntime
    let server: Connection?
    let agents: AgentService = SelfHostedAgentService()
    let workspace: WorkspaceService
    let ssh: SSHConnection
    let host: DockerWorkspaceHost
    let sandbox: ServerSandbox

    init(connection: Connection, remote: RemoteHostConnection, sandbox: ServerSandbox) {
        server = connection
        runtime = .container(serverId: connection.id, sandbox: sandbox)
        self.sandbox = sandbox
        let ssh = SSHConnection.make(for: remote)
        self.ssh = ssh
        host = DockerWorkspaceHost(ssh: ssh)
        workspace = DockerWorkspaceService(host: host, sandbox: sandbox)
    }

    func healthCheck() async -> BackendHealth {
        let began = Date()
        do {
            guard try await host.inspect(sandbox) != nil else { throw DockerWorkspaceError.missing }
            return .init(ok: true, latencyMs: Int(Date().timeIntervalSince(began) * 1000), detail: nil)
        } catch { return .init(ok: false, detail: error.localizedDescription) }
    }
    func dispose() async { ssh.close() }
}

/// Shared file/Git/installer commands execute inside the container. No caller can
/// accidentally fall back to a host path when the sandbox is stopped or missing.
final class DockerWorkspaceService: WorkspaceService {
    let capabilities = WorkspaceCapabilities(files: true, exec: true, terminal: true, ports: false,
        resources: true, power: true, metrics: false, resizable: false)
    let daemonBindHost = "0.0.0.0"
    let usesNativeDaemonService = false
    private let host: DockerWorkspaceHost
    private let sandbox: ServerSandbox
    private let files: SelfHostedWorkspaceService

    init(host: DockerWorkspaceHost, sandbox: ServerSandbox) {
        self.host = host; self.sandbox = sandbox
        files = SelfHostedWorkspaceService { try await host.exec(sandbox, $0) }
    }
    func status() async throws -> WorkspaceStatus {
        guard let info = try await host.inspect(sandbox) else { throw DockerWorkspaceError.missing }
        return .init(power: info.power)
    }
    func getResources() async throws -> WorkspaceResources {
        guard let info = try await host.inspect(sandbox) else { throw DockerWorkspaceError.missing }
        var resources = info.power == .running ? try await files.getResources()
            : WorkspaceResources(cpus: 0, memoryMb: 0, diskMb: 0)
        if info.memory > 0 { resources.memoryMb = Int(info.memory / 1_048_576) }
        if info.nanoCPUs > 0 { resources.cpus = max(1, Int(info.nanoCPUs / 1_000_000_000)) }
        return resources
    }
    func power(_ action: PowerAction) async throws { try await host.power(sandbox, action) }
    func exec(_ cmd: [String]) async throws -> ExecResult { try await files.exec(cmd) }
    func execStream(_ cmd: [String]) -> AsyncThrowingStream<ExecEvent, Error> { host.execStream(sandbox, cmd) }
    func listFiles(_ path: String) async throws -> [FileEntry] { try await files.listFiles(path) }
    func searchFiles(_ query: String, in path: String) async throws -> [FileEntry] { try await files.searchFiles(query, in: path) }
    func readFile(_ path: String) async throws -> FileContent { try await files.readFile(path) }
    func writeFile(_ path: String, content: String) async throws { try await files.writeFile(path, content: content) }
    func deleteFile(_ path: String) async throws { try await files.deleteFile(path) }
    func updateResources(_ patch: WorkspaceResourcePatch) async throws -> WorkspaceResources { throw BackendError.notImplemented("Resize this container on the server.") }
    func listPorts() async throws -> [ExposedPort] { [] }
    func exposePort(_ input: ExposePortInput) async throws -> ExposedPort { throw BackendError.notImplemented("Publish container ports on the server.") }
    func unexposePort(_ port: Int) async throws { throw BackendError.notImplemented("Manage container ports on the server.") }
    func terminalEndpoint() async throws -> WorkspaceTerminalEndpoint { throw BackendError.notImplemented("Container terminals use SSH.") }
}
