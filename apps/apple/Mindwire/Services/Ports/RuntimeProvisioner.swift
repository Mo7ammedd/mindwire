import Foundation

protocol RuntimeProvisioner: AnyObject {
    /// cloud = true (exposes a sizing step); server = false.
    var configurable: Bool { get }
    /// Provisions a workspace, emitting stage updates, and returns the resolved runtime.
    func provision(_ spec: WorkspaceSpec, onStage: ((ProvisionStageKey) -> Void)?) async throws -> AgentRuntime
}
