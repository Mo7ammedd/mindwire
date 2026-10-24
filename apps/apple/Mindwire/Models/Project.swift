import Foundation

/// A named project = a directory (workdir) on a specific workspace. It's the access point
/// where Files + Git + Terminal are reused, and where agents are started (and run). Created
/// from an existing workspace folder, a new directory, or a cloned Git repository.
/// Owned by the workspace registry, cached in UserDefaults `mindwire:projects`.
struct Project: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    /// The workspace this project's directory lives on.
    var workspaceId: String
    /// The workspace directory on that workspace (absolute or ~-relative).
    var path: String
    /// Credential-free origin remote, when cloned from a git host.
    var repoUrl: String?
    let createdAt: String
    var lastUsedAt: String?
    var revision: Int64? = nil
    var gitConnection: GitConnection? = nil
    /// Relative image path owned by the workspace registry. Image bytes are only a local cache.
    var iconPath: String? = nil
    /// One logical project can have preserved copies on multiple workspaces.
    var syncId: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, name, workspaceId, path, repoUrl, createdAt, lastUsedAt, revision, gitConnection, iconPath, syncId
    }
    private enum LegacyCodingKeys: String, CodingKey { case sandboxId }
}

extension Project {
    /// General bots share this managed working directory. Its registry record keeps
    /// conversations attached to their files; it is not a user-facing Developer project.
    static let assistantWorkspaceDirectoryName = ".mindwire-workspace"

    static func isAssistantWorkspacePath(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == assistantWorkspaceDirectoryName
    }

    var isAssistantWorkspace: Bool { Self.isAssistantWorkspacePath(path) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
            ?? legacy.decode(String.self, forKey: .sandboxId)
        path = try c.decode(String.self, forKey: .path)
        repoUrl = try c.decodeIfPresent(String.self, forKey: .repoUrl)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(String.self, forKey: .lastUsedAt)
        revision = try c.decodeIfPresent(Int64.self, forKey: .revision)
        gitConnection = try c.decodeIfPresent(GitConnection.self, forKey: .gitConnection)
        iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
        syncId = try c.decodeIfPresent(String.self, forKey: .syncId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(repoUrl, forKey: .repoUrl)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try c.encodeIfPresent(revision, forKey: .revision)
        try c.encodeIfPresent(gitConnection, forKey: .gitConnection)
        try c.encodeIfPresent(iconPath, forKey: .iconPath)
        try c.encodeIfPresent(syncId, forKey: .syncId)
    }
}

struct CreateProjectInput {
    var name: String
    var workspaceId: String
    var path: String
    var repoUrl: String?
}
