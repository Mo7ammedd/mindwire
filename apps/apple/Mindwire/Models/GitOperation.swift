import Foundation

enum GitAction: String, Codable {
    case stage, unstage, discard, commit, fetch, pull, push
    case switchBranch = "switch_branch"
    case createBranch = "create_branch"
    case restoreCommit = "restore_commit"
    case renameBranch = "rename_branch"
    case deleteBranch = "delete_branch"
    var isRemote: Bool { self == .fetch || self == .pull || self == .push }
    var isFileAction: Bool { self == .stage || self == .unstage || self == .discard }
    var minimumOperationsVersion: Int {
        switch self {
        case .renameBranch, .deleteBranch: return 5
        case .restoreCommit: return 4
        case .switchBranch, .createBranch: return 2
        default: return 1
        }
    }
    var title: String { t(isRemote ? "git.remote.\(rawValue).progress" : "git.\(rawValue)") }
    var completionMessage: String? {
        if isRemote { return t("git.remote.\(rawValue).done") }
        if self == .restoreCommit { return t("git.restore.done") }
        return nil
    }
}

/// Only non-secret intent is cached. Authorization is obtained separately for
/// submission and never becomes part of this request or its saved receipt.
struct GitOperationRequest: Codable, Equatable {
    var id: String
    var action: GitAction
    var paths: [String]?
    var message: String?
    var branch: String?
    var remote: Bool?
    var newName: String?
    var expectedTip: String?
    var force: Bool?
    var identity: GitIdentity?
    var commitId: String?
    var expectedHead: String?
    var expectedBranch: String?
    var minimumOperationsVersion: Int { max(action.minimumOperationsVersion, identity == nil ? 1 : 3) }

    init(id: String = UUID().uuidString, action: GitAction, paths: [String] = [], message: String = "",
         branch: String? = nil, remote: Bool = false, identity: GitIdentity? = nil,
         commitId: String? = nil, expectedHead: String? = nil, expectedBranch: String? = nil,
         newName: String? = nil, expectedTip: String? = nil, force: Bool = false) {
        self.id = id; self.action = action
        self.paths = paths.isEmpty ? nil : Array(Set(paths)).sorted()
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = trimmed.isEmpty ? nil : trimmed
        self.branch = branch
        self.remote = remote ? true : nil
        self.newName = newName
        self.expectedTip = expectedTip
        self.force = force ? true : nil
        self.identity = identity?.normalized
        self.commitId = commitId
        self.expectedHead = expectedHead
        self.expectedBranch = expectedBranch
    }

    func matches(_ other: GitOperationRequest) -> Bool {
        action == other.action && paths == other.paths && message == other.message
            && branch == other.branch && remote == other.remote && identity == other.identity
            && newName == other.newName && expectedTip == other.expectedTip && force == other.force
            && commitId == other.commitId && expectedHead == other.expectedHead && expectedBranch == other.expectedBranch
    }
}

struct GitOperation: Codable, Identifiable {
    let id: String
    let projectId: String
    let action: GitAction
    var paths: [String]?
    var message: String?
    var branch: String?
    var remote: Bool?
    var newName: String?
    var expectedTip: String?
    var force: Bool?
    var identity: GitIdentity?
    var commitId: String?
    var expectedHead: String?
    var expectedBranch: String?
    let status: String
    var output: String?
    var error: String?
    var errorCode: String?
    let createdAt: String
    let updatedAt: String
    let sequence: Int64
    var isActive: Bool { ["queued", "running", "cancelling"].contains(status) }
    var request: GitOperationRequest {
        .init(id: id, action: action, paths: paths ?? [], message: message ?? "", branch: branch, remote: remote == true,
              identity: identity, commitId: commitId, expectedHead: expectedHead, expectedBranch: expectedBranch,
              newName: newName, expectedTip: expectedTip, force: force == true)
    }
}

struct GitOperationReceipt: Codable, Identifiable {
    var id: String { request.id }
    let workspaceId: String
    let registryId: String
    let projectId: String
    let request: GitOperationRequest
}
