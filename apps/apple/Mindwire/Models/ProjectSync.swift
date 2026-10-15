import Foundation

struct ProjectSyncIgnoredPath: Codable, Hashable, Identifiable {
    let path: String
    let kind: String
    let included: Bool
    var id: String { path }
}

struct ProjectSyncFilePreview: Codable, Hashable {
    let version: Int
    let fileCount: Int
    let bytes: Int64
    let ignoredCount: Int
    var ignored: [ProjectSyncIgnoredPath]
    let includeIgnored: [String]
    var next: Int?
    let selectionToken: String
}

enum ProjectSyncSelection {
    static func normalized(_ paths: [String]) -> [String] {
        let unique = Set(paths.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        return unique.filter { path in
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "/" {
                if unique.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }.sorted()
    }
}

struct ProjectSyncEntry: Codable, Hashable {
    let kind: String
    let mode: UInt32
    let size: Int64
    var chunks: [String]?
    var link: String?
    var jsonLines: Bool?
}

struct ProjectSyncCheckpoint: Codable, Hashable {
    let id: String
    let projectId: String
    let parents: [String]
    let manifest: ProjectSyncEntry
    let objectCount: Int
    let bytes: Int64
}

struct ProjectSyncConflict: Codable, Hashable, Identifiable {
    let path: String
    let kind: String
    let message: String
    var id: String { kind + ":" + path }
    var displayPath: String { path.hasPrefix("files/") ? String(path.dropFirst(6)) : path }
}

struct ProjectSyncOperation: Codable, Hashable, Identifiable {
    let id: String
    var projectId: String?
    var checkpointId: String?
    var path: String?
    let kind: String
    var status: String
    var phase: String
    var progress: Double
    var resultProjectId: String?
    var resultCheckpointId: String?
    var recoveryCheckpointId: String?
    var conflicts: [ProjectSyncConflict]?
    var error: String?
    let createdAt: String
    var updatedAt: String

    var active: Bool { ["queued", "exporting", "preparing", "applying"].contains(status) }
}

struct ProjectTransfer: Codable, Identifiable, Hashable {
    let id: String
    let sourceProjectId: String
    let sourceWorkspaceId: String
    let targetWorkspaceId: String
    var syncId: String?
    var destinationPath: String?
    var includeIgnored: [String]?
    var selectionToken: String?
    var sourceIdentity: String?
    var targetIdentity: String?
    var checkpointId: String?
    var didRelay = false
    var phase = "checkpoint"
    var status = "queued"
    var transferredBytes: Int64 = 0
    var completedObjects = 0
    var totalObjects = 0
    var operation: ProjectSyncOperation?
    var resultProjectId: String?
    var error: String?
    let createdAt: String

    var active: Bool { ["queued", "running"].contains(status) }
    var canResume: Bool { ["paused", "failed", "conflicts", "recovery_required"].contains(status) }
    var progress: Double? {
        if status == "succeeded" { return 1 }
        if phase == "transfer", totalObjects > 0 { return min(1, Double(completedObjects) / Double(totalObjects)) }
        if phase == "apply", let operation, operation.progress > 0 { return operation.progress }
        return nil
    }
}

struct ProjectSyncFailure: LocalizedError {
    let operation: ProjectSyncOperation
    var errorDescription: String? {
        operation.error ?? t(operation.status == "conflicts" ? "project.transfer.conflictsBody" : "project.transfer.failed")
    }
}

enum ProjectTransferError: LocalizedError {
    case identityChanged, invalidData, refreshFailed, reviewRequired
    var errorDescription: String? {
        switch self {
        case .identityChanged: t("project.transfer.identityChanged")
        case .invalidData: t("project.transfer.invalidData")
        case .refreshFailed: t("project.transfer.refreshFailed")
        case .reviewRequired: t("project.transfer.legacyReview")
        }
    }
}
