import Foundation

/// Credential source, independent of whether the workspace is cloud or self-hosted.
enum GitHubAuthMode: String, Codable, Hashable {
    case oblienApp  // Oblien GitHub App installation (brokered by Oblien's API)
    case token      // a personal access token, self-managed (talks to GitHub directly)
    case ghCli      // the `gh` CLI already authed on a self-hosted workspace
    case sshKey     // a generated SSH key; clones by URL over SSH (no repo listing — no API)

    var title: String {
        switch self {
        case .oblienApp: return t("github.connect.oblienApp.title")
        case .token: return t("github.connect.token.title")
        case .ghCli: return t("github.connect.gh.title")
        case .sshKey: return t("github.connect.sshKey.title")
        }
    }
}

/// A connected GitHub identity (UserDefaults `mindwire:github`). For `.token`, the secret lives in
/// the Keychain at `KeychainKey.githubToken(id)`. For `.ghCli`, it's tied to a workspace.
struct GitHubAccount: Codable, Identifiable, Hashable {
    let id: String
    var login: String          // GitHub username/org login
    var name: String?          // GitHub profile name, independent of the credential's label
    var label: String? = nil   // user-chosen connection name; older records fall back to their identity
    var lastCheck: GitHubConnectionCheck? = nil
    var avatarUrl: String?
    var mode: GitHubAuthMode
    var workspaceId: String?     // ghCli only: which workspace's `gh`
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id, login, name, label, lastCheck, avatarUrl, mode, workspaceId, createdAt
    }
    private enum LegacyCodingKeys: String, CodingKey { case sandboxId }

    var displayName: String { Self.cleanLabel(label) ?? Self.cleanLabel(name) ?? login }
    var addedDate: Date? { Self.date(createdAt) }
    var connectionLabel: String { "\(displayName) · \(mode.title)" }
    var identityLabel: String {
        mode == .sshKey ? mode.title : "@\(login) · \(mode.title)"
    }

    static func cleanLabel(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func date(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions.insert(.withFractionalSeconds)
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// A past check, never an assertion that a credential is still valid. No secrets or
/// provider error bodies are persisted with connection metadata.
struct GitHubConnectionCheck: Codable, Hashable {
    let checkedAt: String
    let succeeded: Bool
    var date: Date? { GitHubAccount.date(checkedAt) }
}

extension GitHubAccount {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        login = try c.decode(String.self, forKey: .login)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        lastCheck = try c.decodeIfPresent(GitHubConnectionCheck.self, forKey: .lastCheck)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        mode = try c.decode(GitHubAuthMode.self, forKey: .mode)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
            ?? legacy.decodeIfPresent(String.self, forKey: .sandboxId)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(login, forKey: .login)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(lastCheck, forKey: .lastCheck)
        try c.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// An owner you can browse repos under — the account itself or one of its orgs.
struct GitHubOwner: Codable, Identifiable, Hashable {
    var id: String { login }
    let login: String
    let kind: Kind
    var avatarUrl: String?
    enum Kind: String, Codable, Hashable { case user, org }
}

struct GitHubRepo: Codable, Identifiable, Hashable {
    var id: String { fullName }
    let owner: String
    let name: String
    let fullName: String        // "owner/name"
    var isPrivate: Bool
    var defaultBranch: String?
    var description: String?
    var language: String?       // primary language (drives the colored dot)
    var stars: Int = 0
    var updatedAt: String?      // relative ("2d ago") for display
    var cloneUrl: String        // https
    var sshUrl: String
}

extension GitHubRepo {
    /// Build a clone target from a pasted "owner/repo", an SSH (`git@github.com:owner/repo.git`),
    /// or an HTTPS GitHub URL. Shared by direct entry and credential resolution; it never
    /// accepts embedded credentials or a URL for another host.
    static func fromGitInput(_ raw: String) -> GitHubRepo? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("git@github.com:") { value = "ssh://git@github.com/" + value.dropFirst("git@github.com:".count) }
        if value.hasPrefix("github.com/") { value = "https://" + value }
        if value.contains("://") {
            guard let url = URLComponents(string: value), url.scheme == "https" || url.scheme == "ssh",
                  url.host?.lowercased() == "github.com", url.port == nil,
                  url.password == nil, url.query == nil, url.fragment == nil,
                  url.user == nil || (url.scheme == "ssh" && url.user == "git") else { return nil }
            value = String(url.path.dropFirst())
        }
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let owner = parts[0], name = parts[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 100 && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }

        return GitHubRepo(
            owner: owner, name: name, fullName: "\(owner)/\(name)",
            isPrivate: false, defaultBranch: nil, description: nil, language: nil,
            stars: 0, updatedAt: nil,
            cloneUrl: "https://github.com/\(owner)/\(name).git",
            sshUrl: "git@github.com:\(owner)/\(name).git"
        )
    }
}
