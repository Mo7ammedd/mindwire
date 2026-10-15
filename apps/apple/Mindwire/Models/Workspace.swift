import Foundation

struct WorkspaceCapabilities: Codable, Hashable {
    var files: Bool
    var exec: Bool
    var terminal: Bool
    var ports: Bool
    var resources: Bool
    var power: Bool
    /// Live usage metrics (CPU/memory/disk over time). Cloud only — self-hosted has no stats stream.
    var metrics: Bool
    /// Resources can be resized/upgraded (CPU/memory/disk). Cloud workspaces yes; a self-hosted
    /// server's hardware is fixed. Default on for cloud until the API says a workspace can't grow.
    var resizable: Bool

    static let none = WorkspaceCapabilities(files: false, exec: false, terminal: false, ports: false, resources: false, power: false, metrics: false, resizable: false)
    static let full = WorkspaceCapabilities(files: true, exec: true, terminal: true, ports: true, resources: true, power: true, metrics: true, resizable: true)
    /// A self-hosted server (the whole host is the workspace): exec/files/terminal/resources over
    /// SSH, but no managed ports, power control, metrics, or resize. Mirrors `SelfHostedWorkspaceService`.
    static let selfHosted = WorkspaceCapabilities(files: true, exec: true, terminal: true, ports: false, resources: true, power: false, metrics: false, resizable: false)
}

/// One point-in-time live usage sample from the runtime stats stream. Percentages are 0–100.
struct WorkspaceStatsSample: Hashable, Identifiable {
    let id = UUID()
    var cpuPercent: Double
    var memoryPercent: Double
    var memoryUsedMb: Double
    var memoryTotalMb: Double
    var diskPercent: Double
    /// Cumulative network bytes (rx+tx) if reported — the model derives a traffic rate from deltas.
    var networkTotalBytes: Double?
}

enum WorkspacePower: String, Codable, Hashable {
    case running, stopped, starting, stopping, unknown

    var isTransitioning: Bool { self == .starting || self == .stopping }
    var blocksService: Bool { self == .stopped || isTransitioning }

    init(status: String?) {
        switch status?.lowercased() {
        case "running": self = .running
        case "starting", "creating", "booting", "restarting", "provisioning", "resuming", "restoring": self = .starting
        case "stopping", "pausing", "hibernating", "snapshotting": self = .stopping
        case "stopped", "paused", "suspended", "hibernated", "exited", "shutdown": self = .stopped
        default: self = .unknown
        }
    }
}

struct WorkspaceStatus: Codable, Hashable {
    var power: WorkspacePower
    var detail: String?
    var provisioning: WorkspaceProvisioning? = nil
}

struct WorkspaceProvisioning: Codable, Hashable {
    var state: String
    var phase: String?
    var stage: String?
    var message: String?
    var error: String?
    var isFailed: Bool { state == "failed" }
    var isPending: Bool { !["ready", "failed"].contains(state) && phase != "deleting" }
}

struct WorkspaceResources: Codable, Hashable {
    var cpus: Int
    var memoryMb: Int
    var diskMb: Int
}

struct WorkspaceResourcePatch: Hashable {
    var cpus: Int?
    var memoryMb: Int?
    var diskMb: Int?
    var apply: Bool?
}

enum PowerAction: String, Hashable { case start, stop, restart }

struct FileEntry: Codable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let type: Kind
    var size: Int?
    var modifiedAt: String?
    /// Matched by `.gitignore` (per the runtime) — shown dimmed in the browser, VS Code-style.
    var isIgnored: Bool = false

    enum Kind: String, Codable, Hashable { case file, dir }
}

struct FileContent: Codable, Hashable {
    let path: String
    let content: String
    var size: Int?
}

struct ExecResult: Codable, Hashable {
    let exitCode: Int?
    let stdout: String
    let stderr: String
    var truncated: Bool? = nil
}

struct ExposedPort: Codable, Identifiable, Hashable {
    var id: Int { port }
    let port: Int
    let url: String
    var label: String?
    var slug: String?
}

struct ExposePortInput {
    let port: Int
    var label: String?
    var slug: String?
}

struct WorkspaceTerminalEndpoint: Codable, Hashable {
    let wsUrl: String
    let createUrl: String
    let token: String
    let `protocol`: String  // "oblien"
}

// MARK: - Workspace (first-class persisted entity)

/// A named, persisted workspace. Backed by an `AgentRuntime` (Oblien Cloud workspace or a
/// self-hosted server). Agents attach to a workspace by id (shareable). Live status/resources
/// are read from the backend on demand; this record only persists identity + backing + spec.
struct Workspace: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var runtime: AgentRuntime
    var spec: WorkspaceSpec?
    let createdAt: String
    var lastUsedAt: String?
    /// Base image (Docker ref, e.g. `node:22` / `oblien/claude-code:latest`) for cloud workspaces.
    var image: String?

    /// True when this workspace runs on Oblien Cloud (vs a self-hosted server).
    var isCloud: Bool { runtime.isCloud }
}
