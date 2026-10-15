import Foundation
import OblienKit

/// Catalog defaults and storage choices travel together to the SDK boundary.
struct CloudProvisioningOptions: Sendable {
    var image: String = "node:22"
    var preset: String?
    var namespace: String?
    var defaults: WorkspaceConfig?
    var rootDiskId: String?
    var disks: [WorkspaceDiskAttachment] = []
    var idempotencyKey: String = UUID().uuidString

    func request(name: String, spec: WorkspaceSpec) -> WorkspaceCreateParams {
        // A retained root already owns its boot configuration. Image defaults only
        // belong to a fresh root, and explicit resource choices always take precedence.
        var config = rootDiskId == nil ? (defaults ?? .init()) : .init()
        config.cpus = spec.cpus; config.memoryMb = spec.memoryMb
        config.diskSizeMb = rootDiskId == nil ? spec.diskMb : nil
        config.rootDiskId = rootDiskId
        if !disks.isEmpty { config.disks = (config.disks ?? []) + disks }
        return .init(image: rootDiskId == nil ? image : nil, name: name, namespace: namespace,
                     mode: spec.persistent == false ? .temporary : .permanent, config: config,
                     preset: rootDiskId == nil ? preset : nil, waitReady: false, idempotencyKey: idempotencyKey)
    }
}

/// Creation is durable once accepted. The repository surfaces the workspace and its
/// preparation queue follows readiness before installing the Mindwire service.
final class CloudProvisioner: RuntimeProvisioner {
    let configurable = true
    private let name: String
    private let options: CloudProvisioningOptions

    init(name: String, options: CloudProvisioningOptions) {
        self.name = name
        self.options = options
    }

    func provision(_ spec: WorkspaceSpec, onStage: ((ProvisionStageKey) -> Void)?) async throws -> AgentRuntime {
        onStage?(.creating)
        let workspace = try await OblienCloud.client.workspaces.create(options.request(name: name, spec: spec))
        onStage?(.booting)
        return .cloud(workspaceId: workspace.id)
    }
}
