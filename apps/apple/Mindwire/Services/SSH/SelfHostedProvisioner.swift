import Foundation

/// Direct placement verifies the existing host. Sandbox placement creates one persistent
/// Docker environment, following the SDK's SSH/container target model.
final class SelfHostedProvisioner: RuntimeProvisioner {
    let configurable = false
    private let connection: Connection
    private let name: String
    private let sandbox: ServerSandbox?
    private let serviceVersion: String?
    private let makeInstaller: (WorkspaceService) -> DaemonInstaller

    init(connection: Connection, name: String = "Workspace", sandbox: ServerSandbox? = nil, serviceVersion: String? = nil,
         makeInstaller: @escaping (WorkspaceService) -> DaemonInstaller = { ExecDaemonInstaller(workspace: $0) }) {
        self.connection = connection; self.name = name; self.sandbox = sandbox
        self.serviceVersion = serviceVersion
        self.makeInstaller = makeInstaller
    }

    func provision(_ spec: WorkspaceSpec, onStage: ((ProvisionStageKey) -> Void)?) async throws -> AgentRuntime {
        onStage?(.creating)
        if case .local(let local) = connection {
            guard local.computer != nil, sandbox == nil else { throw ComputerConnectionError.notPaired }
            let backend = SelfHostedBackend(connection: connection)
            let health = await backend.healthCheck()
            await backend.dispose()
            guard health.ok else { throw BackendError.message(health.detail ?? ComputerConnectionError.unreachable.localizedDescription) }
            onStage?(.ready)
            return .server(serverId: connection.id)
        }
        guard let remote = connection.remote else {
            throw ComputerConnectionError.notPaired
        }
        if let sandbox, !DaemonRelease.satisfies(serviceVersion ?? sandbox.version, target: ServerSandbox.minimumServiceVersion) {
            throw BackendError.message("Docker workspaces need Mindwire service \(ServerSandbox.minimumServiceVersion) or later.")
        }
        let ssh = SSHConnection.make(for: remote)
        defer { ssh.close() }
        let check = try await ssh.exec(["true"], timeoutSeconds: 15)
        guard check.exitCode == 0 else { throw BackendError.message("Couldn't run commands on this SSH server.") }
        if let sandbox {
            onStage?(.booting)
            let host = DockerWorkspaceHost(ssh: ssh)
            try await host.prepare(sandbox, displayName: name, spec: spec)
            onStage?(.configuring)
            try await prepareService(ssh: ssh, host: host, sandbox: sandbox)
        }
        onStage?(.configuring)
        onStage?(.ready)
        if let sandbox { return .container(serverId: connection.id, sandbox: sandbox) }
        return .server(serverId: connection.id)
    }

    private func prepareService(ssh: SSHConnection, host: DockerWorkspaceHost, sandbox: ServerSandbox) async throws {
        let workspace = DockerWorkspaceService(host: host, sandbox: sandbox)
        // Startup writes the credential before binding HTTP. Wait for that file so
        // the normal credential resolver never invents a competing first-run token.
        for attempt in 0..<40 {
            let ready = try await host.exec(sandbox, ["test", "-s", ServerSandbox.home + "/.mindwire/daemon.token"])
            if ready.exitCode == 0 { break }
            guard attempt < 39 else { throw BackendError.message("The sandbox service didn't finish starting. Try again.") }
            try await Task.sleep(for: .milliseconds(250))
        }
        let token = await WorkspaceDaemonCredential.resolve(workspaceId: sandbox.id, workspace: workspace)
        let channel = SSHTunnelChannel(ssh: ssh, token: token) { try await host.port(sandbox) }
        let http = DaemonHTTP(channel: channel, agentType: "")
        var health: DaemonHealth?
        for attempt in 0..<40 {
            if let current: DaemonHealth = try? await http.decode("GET", "/healthz", quiet: true), current.ok {
                health = current; break
            }
            guard attempt < 39 else { throw BackendError.message("The sandbox service isn't responding. Try again.") }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard var health else { throw BackendError.message("The sandbox service isn't responding.") }
        let target = serviceVersion ?? sandbox.version
        if !DaemonRelease.satisfies(health.version, target: target) {
            try await DaemonUpdateGuard.requireIdle(http: http, health: health)
            try await makeInstaller(workspace).install(agentType: "", cwd: ServerSandbox.home,
                target: target, daemonToken: token, requireUpdateLease: (health.serviceUpdateVersion ?? 0) >= 1,
                onProgress: nil)
            var updated: DaemonHealth?
            for _ in 0..<40 {
                if let value: DaemonHealth = try? await http.decode("GET", "/healthz", quiet: true),
                   value.ok, DaemonRelease.satisfies(value.version, target: target) {
                    updated = value; break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard let updated else {
                throw BackendError.message(t("workspace.daemon.verifyFailed"))
            }
            health = updated
        }
        guard (health.workspaceIsolationVersion ?? 0) >= 1, health.workspaceIsolation == "container" else {
            throw BackendError.message("The Mindwire service hasn't enabled the workspace's container sandbox. Update the service, then try again.")
        }
    }
}
