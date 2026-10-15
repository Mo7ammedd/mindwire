import Foundation

/// Write-only request credentials. Operation responses never contain this type.
struct ProjectCloneAuth: Encodable {
    let kind: String
    var connectionId: String? = nil
    var username: String? = nil
    var token: String? = nil
    var privateKey: String? = nil
    var expiresAt: String? = nil
    var readOnly: Bool? = nil
}

struct ProjectCreateRequest: Encodable {
    let id: String
    let source: String
    let name: String
    let path: String
    var repoUrl: String? = nil
    var branch: String? = nil
    var auth: ProjectCloneAuth? = nil
    var gitConnection: GitConnection? = nil
}

struct ProjectRemoveRequest: Encodable {
    let operationId: String
    let expectedRevision: Int64
}

/// A daemon snapshot. UI may cache it, but never infer a successful clone from logs or files.
struct ProjectOperation: Codable, Identifiable, Hashable {
    let id: String
    let source: String
    let name: String
    let path: String
    var repoUrl: String? = nil
    var branch: String? = nil
    var authKind: String? = nil
    var gitConnection: GitConnection? = nil
    var expectedRevision: Int64? = nil
    var status: String
    var phase: String
    var progress: Double? = nil
    var log: String? = nil
    var error: String? = nil
    var projectId: String? = nil
    let createdAt: String
    var updatedAt: String
    var sequence: Int64
    var attempt: Int

    var isActive: Bool { ["queued", "running", "cancelling"].contains(status) }
    var removesFiles: Bool { source == "delete" }
    var canStop: Bool { isActive && status != "cancelling" && !(removesFiles && phase == "deleting") }
    var canRetry: Bool { ["failed", "cancelled", "interrupted"].contains(status) }
    var phaseLabel: String {
        let value = status == "cancelling" ? status : (isActive ? phase : status)
        if removesFiles {
            return Strings.en["project.operation.remove.\(value)"] ?? t("project.operation.remove.running")
        }
        let key = "project.operation.phase.\(value)"
        return Strings.en[key] ?? t("project.operation.phase.running")
    }
}

struct ProjectOperationReference: Identifiable {
    let workspaceId: String
    let operationId: String
    var id: String { workspaceId + ":" + operationId }
}
