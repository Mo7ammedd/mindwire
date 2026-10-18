import Foundation
import OblienKit

/// Optional control-plane features. A direct SSH host does not inherit cloud infrastructure
/// controls just because it supports files or a terminal.
enum WorkspaceManagementFeature: String, CaseIterable, Hashable, Sendable {
    case disks, desktop, workloads, network, publicAccess, ssh, apiAccess, settings, archives, logs
}

struct ManagedWorkspace: Decodable, Sendable {
    let id: String
    var name: String?
    var slug: String?
    var logo: String?
    var namespace: String?
    var image: String?
    var mode: String?
    var info: Info?
    var lifecycle: WorkspaceLifecycle?
    var imageCapabilities: [String]?
    var resources: Capacity?
    var createdAt: String?
    struct Info: Decodable, Sendable { var status: String?; var isRunning: Bool? }
    struct Capacity: Decodable, Sendable { var cpus: Int?; var memoryMb: Int?; var diskSizeMb: Int? }
    var power: String { info?.status ?? "unknown" }
    var isColdStopped: Bool { ["stopped", "failed", "expired", "ttl-expired"].contains(power) }
    var isRunning: Bool { power == "running" }
    var hasSavedExecution: Bool { ["suspended", "hibernated"].contains(power) }
}

struct WorkspaceLifecycle: Decodable, Sendable {
    var mode: String?
    var status: String?
    var pauseSupported: Bool?
    var snapshotSupported: Bool?
    var snapshotUnavailableReason: String?
    var restartPolicy: String?
    var maxRestarts: Int?
    var ttl: String?
    var ttlAction: String?
    var ttlExpiresAt: String?
    var removeOnExit: Bool?
    var idle: Idle?
    struct Idle: Decodable, Sendable {
        var suspendAfter: Int?
        var stopAfter: Int?
        var suspendAfterSeconds: Int?
        var stopAfterSeconds: Int?
        var sleepSeconds: Int { suspendAfter ?? suspendAfterSeconds ?? 0 }
        var retentionSeconds: Int { stopAfter ?? stopAfterSeconds ?? 0 }
    }
}

struct WorkspaceNetwork: Decodable, Sendable {
    var ip: String?
    var gateway: String?
    var allowInternet: Bool?
    var publicAccess: Bool?
    var ingressPorts: [Int]?
    var egressPorts: [Int]?
    var egress: [String]?
    var outboundIp: String?
    var outboundCountryCode: String?
    var outboundMode: String?
    var outboundProxy: Proxy?
    var privateLinks: [PrivateLink]?
    struct Proxy: Decodable, Sendable { var host: String?; var port: Int?; var `protocol`: String?; var hasCredentials: Bool? }
    struct PrivateLink: Decodable, Identifiable, Sendable {
        var id: String?; var workspaceId: String?; var name: String?; var ip: String?
        var resolvedId: String { workspaceId ?? id ?? "" }
    }
}

struct WorkspaceNetworkPatch: Encodable, Hashable, Sendable {
    var allowInternet: Bool?
    var publicAccess: Bool?
    var ingressPorts: [Int]?
    var egress: [String]?
    var privateLinkIds: [String]?
    var outboundMode: String?
    var customProxy: Proxy?
    struct Proxy: Encodable, Hashable, Sendable {
        var host: String; var port: Int; var `protocol`: String; var username: String?; var password: String?
    }
}

struct WorkspaceOutboundIP: Decodable, Identifiable, Sendable {
    let ip: String
    var countryCode: String?
    var id: String { ip }
}

struct WorkspaceManagedDisk: Decodable, Identifiable, Sendable {
    let id: String
    var name: String?
    var namespace: String?
    var state: String?
    var kind: String?
    var format: String?
    var sizeMb: Int?
    var immutable: Bool?
    var ownership: String?
    var rootImage: String?
    var operationId: String?
    var permissions: [String: Bool]?
    var attachments: [Attachment]?

    struct Attachment: Decodable, Sendable {
        var workspaceId: String
        var mountPath: String?
        var role: String?
        var target: String?
        var readOnly: Bool?
    }
    var displayName: String { name?.nonBlank ?? "Disk" }
    var isSystem: Bool { ownership == "system" }
    var isReadOnly: Bool { immutable == true || isSystem }
    var connections: [Attachment] { attachments ?? [] }
    func permits(_ action: String) -> Bool {
        guard operationId == nil, state == "ready" else { return false }
        // Missing permissions are not an invitation to guess what an older API permits.
        return permissions?[action] == true
    }
    func canAttach(to workspace: ManagedWorkspace) -> Bool {
        permits("attach") && namespace?.nonBlank == workspace.namespace?.nonBlank &&
        !connections.contains { $0.workspaceId == workspace.id } &&
        (isReadOnly || connections.isEmpty) &&
        (kind == "data" || (kind == "root" && isReadOnly && rootImage == workspace.image))
    }
    func canMove(to workspace: ManagedWorkspace, from sourceID: String) -> Bool {
        permits("move") && sourceID != workspace.id && workspace.isColdStopped &&
        namespace?.nonBlank == workspace.namespace?.nonBlank &&
        !connections.contains(where: { $0.workspaceId == workspace.id }) &&
        connections.contains(where: { $0.workspaceId == sourceID }) &&
        (kind == "data" || (kind == "root" && rootImage != nil && rootImage == workspace.image))
    }
}

struct WorkspaceDiskList: Decodable, Sendable {
    var disks: [WorkspaceManagedDisk]
    var operationId: String?
}

struct WorkspaceSoftware: Decodable, Identifiable, Sendable {
    let id: String
    var name: String?
    var label: String?
    var description: String?
    var sizeMb: Int?
    var compatibleImages: [String]?
    var attachment: WorkspaceSoftwareAttachment?
    var displayName: String { label?.nonBlank ?? name?.nonBlank ?? "Software" }
}
struct WorkspaceSoftwareAttachment: Decodable, Sendable { var target: String?; var role: String?; var readOnly: Bool? }

struct WorkspaceDiskOperation: Decodable, Sendable {
    let id: String
    var state: String
    var phase: String?
    var error: String?
    var isPending: Bool { state == "queued" || state == "running" }
}
struct WorkspaceDiskResult: Decodable, Sendable {
    var disk: WorkspaceManagedDisk?
    var operation: WorkspaceDiskOperation?
}

/// The same typed command drives disk forms, operation retries, and the cloud adapter.
struct WorkspaceDiskAction: Hashable, Sendable {
    enum Kind: String, Sendable { case create, attach, detach, move, clone, save, fork, resize, retain, delete, attachSoftware, discardSavedExecution, retry }
    var kind: Kind
    var diskId: String?
    var operationId: String?
    var targetWorkspaceId: String?
    var name: String?
    var namespace: String?
    var sizeMb: Int?
    var format: String?
    var mountPath: String?
    var target: String?
    var readOnly: Bool?
    var role: String?
}

struct WorkspaceDesktopAccess: Sendable {
    var supported: Bool
    var enabled: Bool
    var available: Bool
    var credentials: Bool?
}

struct WorkspaceDesktopInstallation: Decodable, Sendable {
    var installable: Bool?
    var installed: Bool?
    var phase: String
    var stage: String?
    var error: String?
    var choices: [Choice]?
    var workloadId: String?
    struct Choice: Decodable, Identifiable, Sendable {
        let id: String
        var label: String
        var description: String?
        var minimumMemoryMb: Int?
    }
    var isPending: Bool { phase == "installing" }
    var isInstalled: Bool { installed == true || ["ready", "restart_required"].contains(phase) }
    var isPrepared: Bool { !(choices ?? []).isEmpty }
}

struct WorkspaceManagedWorkload: Decodable, Identifiable, Sendable {
    let id: String
    var name: String?
    var state: String?
    var status: String?
    var command: [String]?
    var target: String?
    var pid: Int?
    var restartPolicy: String?
    var maxRestarts: Int?
    var restartCount: Int?
    var startedAt: String?
    var exitCode: Int?
    var origin: String?
    var workingDirectory: String?
    var displayName: String { name?.nonBlank ?? "Process \(id)" }
    var currentState: String { state ?? status ?? "unknown" }
    var isRunning: Bool { currentState == "running" }
}

struct WorkspaceExecutionTarget: Identifiable, Sendable {
    let id: String
    var label: String
    var available: Bool
    var isDefault: Bool
}

struct WorkspaceWorkloadMetrics: Identifiable, Sendable {
    let id: String
    var state: String?
    var cpuPercent: Double?
    var memoryBytes: Double?
    var uptimeSeconds: Double?
    var pid: Int?
    var ports: [Int]?

    var cpuLabel: String? { cpuPercent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } }
    var memoryLabel: String? {
        guard let memoryBytes, memoryBytes >= 0, memoryBytes < Double(Int64.max) else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }
    var uptimeLabel: String? {
        guard let uptimeSeconds, uptimeSeconds >= 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = uptimeSeconds >= 3600 ? [.day, .hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: uptimeSeconds)
    }
}

struct WorkspaceEnvironmentVariable: Identifiable, Hashable, Sendable {
    var id = UUID()
    var key = ""
    var value = ""
}

struct WorkspaceWorkloadDraft: Hashable, Sendable {
    var name = ""
    var command = ""
    var directory = ""
    var target = ""
    var environment: [WorkspaceEnvironmentVariable] = []
    var restartPolicy = "never"
    var maxRestarts: Int = 0
    var maxLogSizeMb: Int = 10
    var logRetentionHours: Int = 168
}

struct WorkspaceLogEntry: Identifiable, Sendable {
    let id: UUID
    var line: String
    var timestamp: String?
    init(line: String, timestamp: String? = nil) { id = UUID(); self.line = line; self.timestamp = timestamp }
}
enum WorkspaceLogSource: Hashable, Sendable { case boot, workload(String) }
struct WorkspaceLogEvent: Sendable { var entries: [WorkspaceLogEntry]; var cleared = false }
struct WorkspaceLogConfig: Decodable, Sendable {
    var maxLogSizeMb: Int?
    var logRetentionHours: Int?
    var storedBytes: Int?
    var droppedLines: Int?
}

struct WorkspaceSSHAccess: Decodable, Sendable {
    var supported: Bool?
    var sshEnabled: Bool?
    var authMethods: [String]?
    var passwordAuthEnabled: Bool?
    var passwordAffectsDesktop: Bool?
    var sshKeySet: Bool?
    var password: String?
    var connection: Connection?
    struct Connection: Decodable, Sendable {
        var command: String?; var user: String?; var host: String?; var bastion: String?
        var scpUpload: String?; var scpDownload: String?
    }
}

struct WorkspaceRuntimeAccess: Decodable, Sendable { var enabled: Bool? }

struct WorkspaceDomain: Decodable, Sendable {
    var customDomain: String?
    var port: Int?
    var includeWww: Bool?
    var sslStatus: String?
    var sslExpiry: String?
    var sslError: String?
}
struct WorkspaceDomainCheck: Decodable, Sendable {
    var verified: Bool?
    var errors: [String]?
    var requiredRecords: Records?
    var edgeIps: [String]?
    struct Records: Decodable, Sendable {
        var cname: CNAME?; var txt: TXT?
        struct CNAME: Decodable, Sendable { var host: String?; var target: String? }
        struct TXT: Decodable, Sendable { var host: String?; var value: String? }
    }
}

struct WorkspaceArchive: Decodable, Identifiable, Sendable {
    var version: String
    var name: String?
    var createdAt: String?
    var sizeBytes: Int?
    var id: String { version }
}

typealias WorkspaceImageOption = WorkspaceImage

enum WorkspaceManagementCommand: Hashable, Sendable {
    case disk(WorkspaceDiskAction, idempotencyKey: String)
    case installDesktop(choice: String?, restart: Bool)
    case desktopAccess(Bool)
    case network(WorkspaceNetworkPatch)
    case outboundIP(String)
    case createWorkload(WorkspaceWorkloadDraft)
    case updateWorkload(id: String, name: String, restartPolicy: String, maxRestarts: Int)
    case workload(id: String, action: WorkloadAction)
    case logRetention(id: String, sizeMb: Int, hours: Int)
    case clearLogs(String)
    case exposePort(port: Int, label: String?, slug: String?)
    case updatePortSlug(port: Int, slug: String)
    case revokePort(Int)
    case connectDomain(domain: String, port: Int, includeWww: Bool)
    case checkDomain(String)
    case removeDomain, renewSSL
    case sshAccess(Bool), sshPassword(String), sshPublicKey(String)
    case runtimeAccess(Bool), runtimeToken(raw: Bool), rotateRuntimeToken
    case identity(name: String, slug: String?, logo: String?)
    case lifecycle(mode: String, restartPolicy: String, maxRestarts: Int, ttl: String, ttlAction: String, removeOnExit: Bool)
    case idle(suspendAfter: Int, stopAfter: Int)
    case pause, resume, hibernate, restore
    case reinstall, retryCreation
    case createArchive(version: Int?, paths: [String]?, excludes: [String]?), deleteArchive(String), renewTTL
    enum WorkloadAction: String, Sendable { case start, stop, delete }
}

enum WorkspaceManagementResult: Sendable {
    case completed
    case disk(WorkspaceDiskResult)
    case desktop(WorkspaceDesktopInstallation)
    case ssh(WorkspaceSSHAccess)
    case credential(String)
    case domainCheck(WorkspaceDomainCheck)
}

struct WorkspaceControlError: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
    static func describe(_ error: Error) -> String {
        if let error = error as? WorkspaceControlError { return error.message }
        if let api = error as? OblienError {
            if api.kind == .decoding { return "This workspace returned an unsupported response. Refresh or update its runtime and try again." }
            if let message = api.message, !message.isEmpty, (api.status ?? 500) < 500,
               !message.contains("dial tcp"), !message.contains("127.0.0.1"), !message.hasPrefix("{") { return message }
            if let status = api.status { return describe(APIError.http(status: status, detail: nil)) }
            return "Could not reach the workspace. Check your connection and try again."
        }
        if case APIError.http(let status, let detail) = error {
            if let data = detail?.data(using: .utf8),
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = body["message"] as? String, !message.isEmpty,
               !message.contains("dial tcp"), !message.contains("127.0.0.1") { return message }
            switch status {
            case 401: return "Sign in to Mindwire again to manage this workspace."
            case 403: return "Your account cannot change this workspace setting."
            case 404: return "This control is not available on this workspace."
            case 409: return "The workspace cannot make this change in its current state. Refresh its status and try again."
            case 429: return "Too many requests. Wait a moment and try again."
            case 500...599: return "Mindwire could not complete this request. Try again shortly."
            default: return "The change could not be completed. Refresh and try again."
            }
        }
        if error is DecodingError { return "This workspace returned an unsupported response. Refresh or update its runtime and try again." }
        if let urlError = error as? URLError, urlError.code == .cancelled { return "The request was cancelled." }
        return "Could not reach the workspace. Check your connection and try again."
    }
}

enum WorkspaceControlValidation {
    static func ports(_ text: String) throws -> [Int] {
        let parts = text.split { $0 == "," || $0.isWhitespace }
        let ports = try parts.map { part -> Int in
            guard let port = Int(part), (1...65535).contains(port) else {
                throw WorkspaceControlError(message: "Ports must be numbers between 1 and 65535.")
            }
            return port
        }
        let unique = Array(Set(ports)).sorted()
        guard unique.count <= 50 else { throw WorkspaceControlError(message: "Use at most 50 ports.") }
        return unique
    }
    static func slug(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$", options: .regularExpression) != nil
    }
    static func mountPath(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        let pieces = value.split(separator: "/")
        guard value.hasPrefix("/"), value != "/", !pieces.contains(".."), !pieces.contains("."),
              !value.contains("//"), !value.contains("\0"), !value.contains("\n") else { return false }
        return !["bin", "sbin", "usr", "etc", "proc", "sys", "dev", "run", "boot", "lib", "lib64"].contains(String(pieces.first ?? ""))
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension String {
    var nonBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
