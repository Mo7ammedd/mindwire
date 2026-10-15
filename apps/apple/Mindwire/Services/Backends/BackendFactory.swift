import Foundation

/// The single switch point between adapter families. Everything above works against the
/// `Backend`/`AgentService`/`WorkspaceService`/`AgentTransport` ports and is oblivious to
/// cloud-vs-server — the only distinction made here.
enum BackendFactory {
    /// Resolve a backend from a runtime. Reusable agents have no runtime — the running context
    /// always comes from a project's workspace, so callers pass `workspace.runtime`.
    static func make(forRuntime runtime: AgentRuntime, stores: Stores) -> Backend {
        switch runtime {
        case .cloud(let workspaceId):
            return CloudBackend(workspaceId: workspaceId)
        case .server(let serverId):
            if let connection = stores.connections.get(serverId) {
                return SelfHostedBackend(connection: connection)
            }
            return MissingServerBackend(runtime: runtime)
        case .container(let serverId, let sandbox):
            if let connection = stores.connections.get(serverId), let remote = connection.remote {
                return DockerWorkspaceBackend(connection: connection, remote: remote, sandbox: sandbox)
            }
            return MissingServerBackend(runtime: runtime)
        }
    }

    static func make(for connection: Connection) -> Backend {
        SelfHostedBackend(connection: connection)
    }

    static func provisioner(for choice: ProvisionChoice, name: String = "agent",
                            cloud: CloudProvisioningOptions? = nil, sandbox: ServerSandbox? = nil, serviceVersion: String? = nil) -> RuntimeProvisioner {
        switch choice {
        case .cloud: return CloudProvisioner(name: name, options: cloud ?? .init())
        // Server-as-workspace: verify SSH reachability and use the server as the runtime.
        case .server(let connection): return SelfHostedProvisioner(connection: connection, name: name, sandbox: sandbox,
                                                                 serviceVersion: serviceVersion)
        }
    }

    /// Daemon transport for an already-created backend, choosing the cleanest channel — all ride
    /// the same `DaemonHTTP` / `AgentTransport` contract, so callers are oblivious:
    ///   • Oblien Cloud → the runtime **proxy** (gateway JWT + Mindwire token, streaming-capable)
    ///   • self-hosted VPS → a native SSH **direct-tcpip tunnel** (no shell)
    ///   • anything else → **curl-over-exec** (the universal fallback)
    /// `agentType` scopes every call to that agent on the one per-workspace daemon (which hosts all
    /// adapters and routes on `?agent=<type>`).
    static func transport(forBackend backend: Backend, agentType: String, daemonToken: String? = nil) -> AgentTransport {
        ExecDaemonTransport(channel: daemonChannel(forBackend: backend, daemonToken: daemonToken), agentType: agentType)
    }

    /// Workspace metadata and harness operations share exactly the same authenticated channel.
    static func daemonChannel(forBackend backend: Backend, daemonToken: String? = nil) -> DaemonChannel {
        if let computer = backend.workspace as? ComputerWorkspaceService { return computer.channel }
        if let container = backend as? DockerWorkspaceBackend {
            return SSHTunnelChannel(ssh: container.ssh, token: daemonToken) {
                try await container.host.port(container.sandbox)
            }
        }
        if let ssh = (backend as? SelfHostedBackend)?.daemonSSH {
            return SSHTunnelChannel(ssh: ssh, token: daemonToken)
        }
        if case .cloud(let workspaceId?) = backend.runtime, let daemonToken, !daemonToken.isEmpty {
            return ProxyDaemonChannel(workspaceId: workspaceId, daemonToken: daemonToken)
        }
        // Universal fallback for a non-cloud runtime without native SSH.
        return CurlExecChannel(workspace: backend.workspace, token: daemonToken)
    }

    /// Daemon installer for a backend, choosing how the binary gets into the workspace — same
    /// interface, impl by type: Oblien Cloud pushes the device-fetched binary in over the files API
    /// (runtime-exec can't do outbound HTTPS); self-hosted `curl`s it directly over the exec/SSH seam.
    static func daemonInstaller(forBackend backend: Backend) -> DaemonInstaller {
        if let computer = backend.workspace as? ComputerWorkspaceService { return ComputerDaemonInstaller(channel: computer.channel) }
        if backend.runtime.isCloud {
            return UploadDaemonInstaller(workspace: backend.workspace)
        }
        return ExecDaemonInstaller(workspace: backend.workspace)
    }

    /// Source-control service over an already-created backend's exec seam (direct `git -C <root>`).
    /// `root` scopes git to a project workdir; `nil` = the workspace's default cwd. No daemon — works
    /// the same on cloud and self-hosted SSH.
    static func gitService(forBackend backend: Backend, root: String? = nil) -> GitService {
        ExecGitService(workspace: backend.workspace, root: root)
    }

    /// GitHub adapter for a connected account, chosen by its auth mode. `.ghCli` runs `gh` on the
    /// account's workspace, so it needs `stores` to resolve + build that backend.
    static func githubService(for account: GitHubAccount, stores: Stores) -> GitHubService {
        switch account.mode {
        case .oblienApp: return OblienGitHubService()
        case .token:     return TokenGitHubService()
        case .ghCli:     return GhCliGitHubService(stores: stores)
        case .sshKey:    return SshKeyGitHubService()
        }
    }

    /// Push registration service against the Oblien device registry, backed by Firebase Cloud
    /// Messaging. Live once `GoogleService-Info.plist` is present and an APNs key is configured.
    @MainActor
    static func pushService() -> PushService {
        LivePushService.shared
    }
}
