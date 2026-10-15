import Foundation

/// Infrastructure management is separate from the runtime's files/exec/terminal contract.
/// Providers opt into individual features; views never infer them from an OS or SSH connection.
protocol WorkspaceManagementService: AnyObject {
    var features: Set<WorkspaceManagementFeature> { get }
    func workspace() async throws -> ManagedWorkspace
    func workspaces() async throws -> [ManagedWorkspace]
    func disks() async throws -> WorkspaceDiskList
    func allDisks() async throws -> [WorkspaceManagedDisk]
    func software() async throws -> [WorkspaceSoftware]
    func diskOperation(_ id: String) async throws -> WorkspaceDiskOperation
    func desktopInstallation() async throws -> WorkspaceDesktopInstallation
    func desktopStatus() async throws -> WorkspaceDesktopAccess
    func workloads() async throws -> [WorkspaceManagedWorkload]
    func workloadTargets() async throws -> [WorkspaceExecutionTarget]
    func workloadStatsStream() -> AsyncThrowingStream<[WorkspaceWorkloadMetrics], Error>
    func network() async throws -> WorkspaceNetwork
    func outboundIPs() async throws -> [WorkspaceOutboundIP]
    func publicPorts() async throws -> [ExposedPort]
    func domain() async throws -> WorkspaceDomain?
    func ssh() async throws -> WorkspaceSSHAccess
    func runtimeAccess() async throws -> WorkspaceRuntimeAccess
    func lifecycle() async throws -> WorkspaceLifecycle
    func archives() async throws -> [WorkspaceArchive]
    func images() async throws -> [WorkspaceImageOption]
    func logConfig(_ id: String) async throws -> WorkspaceLogConfig
    func logs(_ source: WorkspaceLogSource) async throws -> [WorkspaceLogEntry]
    func logStream(_ source: WorkspaceLogSource) -> AsyncThrowingStream<WorkspaceLogEvent, Error>
    func perform(_ command: WorkspaceManagementCommand) async throws -> WorkspaceManagementResult
}
