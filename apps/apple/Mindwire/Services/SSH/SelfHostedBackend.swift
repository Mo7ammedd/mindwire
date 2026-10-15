import Foundation

/// `Backend` for a self-hosted server. Remote (SSH/VPS) hosts get a real exec/file/resource
/// surface over `SSHConnection`. Paired computers use the same daemon API over pinned SSH.
///
/// Docker isolation uses `DockerWorkspaceBackend` and the same workspace/daemon ports.
final class SelfHostedBackend: Backend {
    let runtime: AgentRuntime
    let server: Connection?
    let agents: AgentService
    let workspace: WorkspaceService
    private let connection: SSHConnection?

    /// The live SSH connection, exposed so the daemon transport can open a native direct-tcpip
    /// tunnel to `127.0.0.1:<daemonPort>` instead of curl-over-exec. nil for paired/local hosts.
    var daemonSSH: SSHConnection? { connection }

    init(connection conn: Connection) {
        self.server = conn
        self.runtime = .server(serverId: conn.id)
        self.agents = SelfHostedAgentService()
        if let remote = conn.remote {
            let ssh = SSHConnection.make(for: remote)
            self.connection = ssh
            self.workspace = SelfHostedWorkspaceService(ssh: ssh)
        } else if case .local(let local) = conn, let computer = local.computer {
            self.connection = nil
            self.workspace = ComputerWorkspaceService(computer: computer)
        } else {
            self.connection = nil
            self.workspace = UnavailableWorkspaceService()
        }
    }

    func healthCheck() async -> BackendHealth {
        if let computer = workspace as? ComputerWorkspaceService {
            let started = Date()
            do {
                _ = try await computer.status()
                return BackendHealth(ok: true, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            } catch { return BackendHealth(ok: false, detail: error.localizedDescription) }
        }
        guard let connection else {
            return BackendHealth(ok: false, latencyMs: nil, detail: ComputerConnectionError.notPaired.localizedDescription)
        }
        let started = Date()
        do {
            let result = try await connection.exec(["true"], timeoutSeconds: 15)
            guard result.exitCode == 0 else { throw BackendError.message("The server didn't allow an SSH command.") }
            return BackendHealth(ok: true, latencyMs: Int(Date().timeIntervalSince(started) * 1000), detail: nil)
        } catch {
            return BackendHealth(ok: false, latencyMs: nil, detail: error.localizedDescription)
        }
    }

    func dispose() async {
        connection?.close()
        if let computer = workspace as? ComputerWorkspaceService { await computer.channel.close() }
    }
}

/// Agent sessions are owned by Mindwire and reached through `ExecDaemonTransport`; this service is
/// retained only for the higher-level backend protocol.
final class SelfHostedAgentService: AgentService {
    func listSessions() async throws -> [AgentSession] { [] }
    func getSession(_ id: String) async throws -> AgentSession? { nil }
    func startSession(_ input: StartAgentInput) async throws -> AgentSession {
        throw BackendError.notImplemented("self-hosted startSession")
    }
    func stopSession(_ id: String) async throws {}
}

/// Server-as-workspace: exec/files/resources implemented with plain shell over SSH.
final class SelfHostedWorkspaceService: WorkspaceService {
    let capabilities = WorkspaceCapabilities(
        files: true, exec: true, terminal: true, ports: false, resources: true, power: false, metrics: false, resizable: false
    )
    private let execute: @Sendable ([String]) async throws -> ExecResult
    private let ssh: SSHConnection?

    init(ssh: SSHConnection) { self.ssh = ssh; execute = { try await ssh.exec($0) } }
    init(execute: @escaping @Sendable ([String]) async throws -> ExecResult) { self.execute = execute; ssh = nil }

    func exec(_ cmd: [String]) async throws -> ExecResult { try await execute(cmd) }
    func execStream(_ cmd: [String]) -> AsyncThrowingStream<ExecEvent, Error> {
        ssh?.execStream(cmd) ?? bufferedExecStream(cmd)
    }

    func status() async throws -> WorkspaceStatus {
        let result = try await exec(["true"])
        guard result.exitCode == 0 else { throw BackendError.message("The server didn't allow an SSH command.") }
        return WorkspaceStatus(power: .running, detail: nil)
    }

    func getResources() async throws -> WorkspaceResources {
        let out = try await exec(["bash", "-lc", """
            if [ "$(uname -s)" = Darwin ]; then
              sysctl -n hw.logicalcpu
              sysctl -n hw.memsize | awk '{printf "%.0f\\n", $1/1048576}'
            else
              getconf _NPROCESSORS_ONLN
              awk '/MemTotal:/{printf "%.0f\\n", $2/1024}' /proc/meminfo
            fi
            df -Pk . | awk 'NR==2{printf "%.0f\\n", $2/1024}'
            """]).stdout
        let nums = out.split(separator: "\n").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return WorkspaceResources(
            cpus: nums.count > 0 ? nums[0] : 0,
            memoryMb: nums.count > 1 ? nums[1] : 0,
            diskMb: nums.count > 2 ? nums[2] : 0
        )
    }

    func listFiles(_ path: String) async throws -> [FileEntry] {
        let dir = path.isEmpty ? "." : path
        let out = try await exec(shell.command(shell.listDir(dir))).stdout
        return out.split(separator: "\n").compactMap { raw -> FileEntry? in
            let name = String(raw)
            let isDir = name.hasSuffix("/")
            let clean = isDir ? String(name.dropLast()) : name
            guard clean != ".git" else { return nil }   // hide the git dir (no gitignore dimming over SSH yet)
            let full = dir.hasSuffix("/") ? "\(dir)\(clean)" : "\(dir)/\(clean)"
            return FileEntry(name: clean, path: full, type: isDir ? .dir : .file, size: nil, modifiedAt: nil)
        }
    }

    func searchFiles(_ query: String, in path: String) async throws -> [FileEntry] {
        let dir = path.isEmpty ? "." : path
        let out = try await exec(shell.command(shell.find(query, in: dir))).stdout
        return out.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let full = String(parts[1])
            return FileEntry(name: (full as NSString).lastPathComponent, path: full,
                             type: parts[0] == "d" ? .dir : .file, size: nil, modifiedAt: nil)
        }
    }

    func readFile(_ path: String) async throws -> FileContent {
        let out = try await exec(shell.command(shell.readFile(path))).stdout
        return FileContent(path: path, content: out, size: out.count)
    }

    func writeFile(_ path: String, content: String) async throws {
        let b64 = Data(content.utf8).base64EncodedString()
        _ = try await exec(shell.command(shell.writeFile(path, base64: b64)))
    }

    func deleteFile(_ path: String) async throws {
        _ = try await exec(shell.command(shell.remove([path])))
    }

    func updateResources(_ patch: WorkspaceResourcePatch) async throws -> WorkspaceResources { throw unsupported() }
    func power(_ action: PowerAction) async throws { throw unsupported() }
    func listPorts() async throws -> [ExposedPort] { [] }
    func exposePort(_ input: ExposePortInput) async throws -> ExposedPort { throw unsupported() }
    func unexposePort(_ port: Int) async throws { throw unsupported() }
    func terminalEndpoint() async throws -> WorkspaceTerminalEndpoint { throw unsupported() }

    private func unsupported() -> BackendError { .notImplemented("not supported for a self-hosted server") }
}

/// A saved connection whose credentials need to be restored.
final class UnavailableWorkspaceService: WorkspaceService {
    let capabilities: WorkspaceCapabilities = .none
    private let reason: String
    init(reason: String = ComputerConnectionError.notPaired.localizedDescription) { self.reason = reason }
    private func u() -> BackendError { .notImplemented(reason) }
    func status() async throws -> WorkspaceStatus { throw u() }
    func getResources() async throws -> WorkspaceResources { throw u() }
    func updateResources(_ patch: WorkspaceResourcePatch) async throws -> WorkspaceResources { throw u() }
    func power(_ action: PowerAction) async throws { throw u() }
    func listPorts() async throws -> [ExposedPort] { throw u() }
    func exposePort(_ input: ExposePortInput) async throws -> ExposedPort { throw u() }
    func unexposePort(_ port: Int) async throws { throw u() }
    func listFiles(_ path: String) async throws -> [FileEntry] { throw u() }
    func readFile(_ path: String) async throws -> FileContent { throw u() }
    func writeFile(_ path: String, content: String) async throws { throw u() }
    func deleteFile(_ path: String) async throws { throw u() }
    func exec(_ cmd: [String]) async throws -> ExecResult { throw u() }
    func terminalEndpoint() async throws -> WorkspaceTerminalEndpoint { throw u() }
}

/// A missing SSH connection must never silently become a cloud or direct-host backend.
final class MissingServerBackend: Backend {
    let runtime: AgentRuntime
    let server: Connection? = nil
    let agents: AgentService = SelfHostedAgentService()
    let workspace: WorkspaceService = UnavailableWorkspaceService(reason: "Add this workspace's SSH server again to reconnect.")
    init(runtime: AgentRuntime) { self.runtime = runtime }
    func healthCheck() async -> BackendHealth { .init(ok: false, detail: "This workspace's SSH server is unavailable.") }
    func dispose() async {}
}
