import Foundation
import OblienKit

/// `Backend` for Oblien Cloud (managed workspaces). Cloud is a runtime, never a saved server.
final class CloudBackend: Backend {
    let runtime: AgentRuntime
    let server: Connection? = nil
    let agents: AgentService
    let workspace: WorkspaceService

    init(workspaceId: String?) {
        self.runtime = .cloud(workspaceId: workspaceId)
        self.agents = CloudAgentService()
        self.workspace = CloudWorkspaceService(workspaceId: workspaceId)
    }

    /// Cloud health = the workspace exists and is reachable on the management API. There is no
    /// `/v1/health` endpoint; we read the workspace record (`GET /workspace/:id`) and report its
    /// power state. Reachable-but-stopped is still "ok" (the panel can start it); only a failed
    /// fetch (gone / no session / network) is unhealthy.
    func healthCheck() async -> BackendHealth {
        guard let id = runtime.workspaceId else {
            return BackendHealth(ok: false, latencyMs: nil, detail: "No workspace")
        }
        guard await OblienAuth.shared.ensure() else {
            return BackendHealth(ok: false, latencyMs: nil, detail: "Sign in to Oblien to access this cloud workspace.")
        }
        let started = Date()
        do {
            let workspace = try await OblienCloud.client.workspaces.get(id)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return BackendHealth(ok: true, latencyMs: latency,
                                 detail: workspace.isRunning ? nil : (workspace.info?.status ?? workspace.status ?? "stopped"))
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return BackendHealth(ok: false, latencyMs: nil, detail: detail)
        }
    }

    func dispose() async {}
}
