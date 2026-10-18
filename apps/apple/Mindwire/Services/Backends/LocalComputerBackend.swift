import Foundation

/// This computer is a runtime, not a paired SSH connection.
final class LocalComputerBackend: Backend {
    let runtime: AgentRuntime
    let server: Connection? = nil
    let agents: AgentService = SelfHostedAgentService()
    let workspace: WorkspaceService

    init(computerId: String) {
        runtime = .local(computerId: computerId)
        #if targetEnvironment(macCatalyst)
        workspace = LocalComputerWorkspaceService(computerId: computerId)
        #else
        workspace = UnavailableWorkspaceService(reason: "Open Mindwire on this Mac to access its local workspace.")
        #endif
    }

    func healthCheck() async -> BackendHealth {
        let started = Date()
        do {
            _ = try await workspace.status()
            return .init(ok: true, latencyMs: Int(Date().timeIntervalSince(started) * 1_000))
        } catch { return .init(ok: false, detail: error.localizedDescription) }
    }
    func dispose() async {}
}

#if targetEnvironment(macCatalyst)
final class LocalComputerWorkspaceService: DaemonWorkspaceService {
    let capabilities = WorkspaceCapabilities.selfHosted
    let daemonChannel: any StreamingDaemonChannel
    // LocalDaemonChannel reads the private computer credential. It never enters the
    // shared keychain or the phone's pairing / credential-recovery flow.
    let daemonToken: String? = nil
    init(computerId: String) { daemonChannel = LocalDaemonChannel(computerId: computerId) }
}

struct LocalComputerInstaller: DaemonInstaller {
    func startInstalled(daemonToken: String) async throws {
        _ = try await LocalComputerRuntime.shared.connect()
    }
    func install(agentType: String, cwd: String, target: String, daemonToken: String,
                 requireUpdateLease: Bool, force: Bool,
                 onProgress: (@Sendable (DaemonInstallProgress) -> Void)?) async throws {
        // Do not replace a running CLI-owned service or interrupt its conversations.
        throw BackendError.message("Update Mindwire or its computer service to update this Mac's runtime.")
    }
}
#endif
