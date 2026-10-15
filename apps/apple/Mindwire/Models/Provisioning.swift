import Foundation

struct WorkspaceSpec: Codable, Hashable {
    var cpus: Int
    var memoryMb: Int
    var diskMb: Int
    var persistent: Bool?
}

struct WorkspaceLimit: Hashable {
    let min: Int
    let max: Int
    func clamp(_ v: Int) -> Int { Swift.max(min, Swift.min(max, v)) }
}

/// UI clamps sizing to these.
enum WorkspaceLimits {
    static let cpus = WorkspaceLimit(min: 1, max: 32)
    static let memoryMb = WorkspaceLimit(min: 128, max: 65536)
    static let diskMb = WorkspaceLimit(min: 64, max: 204800)
}

enum ProvisionStageKey: String, Codable, CaseIterable, Hashable { case creating, booting, configuring, ready }

enum WorkspaceSpecs {
    /// Used only for self-hosted records, whose actual resources come from the host.
    static let selfHostedDefault = WorkspaceSpec(cpus: 2, memoryMb: 4096, diskMb: 20480, persistent: true)
}

/// Where to provision a new workspace.
enum ProvisionChoice: Hashable {
    case cloud
    case server(Connection)
}
