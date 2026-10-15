import Foundation

enum GitCredentialLifetime: String, Codable, CaseIterable, Hashable {
    case run, workspace
    var title: String { t(self == .run ? "github.access.run" : "github.access.workspace") }
}

/// Shared, non-secret project/workspace preference. The daemon owns this record;
/// a matching local account can supply a credential for an individual operation.
struct GitConnection: Codable, Hashable, Identifiable {
    let id: String
    let login: String
    let mode: String
    var lifetime: GitCredentialLifetime

    init(account: GitHubAccount, lifetime: GitCredentialLifetime = .run) {
        id = account.id
        login = account.login
        mode = account.mode.rawValue
        switch account.mode {
        case .oblienApp: self.lifetime = .run
        case .ghCli: self.lifetime = .workspace
        default: self.lifetime = lifetime
        }
    }

    private init(id: String, login: String, mode: String, lifetime: GitCredentialLifetime) {
        self.id = id; self.login = login; self.mode = mode; self.lifetime = lifetime
    }

    static var server: GitConnection { .init(id: "native", login: t("github.access.server"), mode: "native", lifetime: .workspace) }
    var usesServerCredentials: Bool { mode == "native" || mode == GitHubAuthMode.ghCli.rawValue }
    var readOnly: Bool { mode == GitHubAuthMode.oblienApp.rawValue }
    var label: String { GitHubAuthMode(rawValue: mode).map { "\(login) · \($0.title)" } ?? login }
}

struct WorkspaceGitState: Decodable {
    var `default`: GitConnection?
    var storedConnectionIds: [String]
    var storedConnections: [GitConnection]? = nil
    var activeOperations: Int? = nil
}

struct ProjectGitState: Decodable {
    var connection: GitConnection?
    var inherited: Bool
    var stored: Bool
    var repoUrl: String?
}

enum GitRemoteOperation: String, CaseIterable, Identifiable {
    case fetch, pull, push
    var id: String { rawValue }
    var title: String { t("git.remote.\(rawValue)") }
}

struct GitRemoteResult: Decodable { let output: String }

/// Older services return Git's terminal-only diagnostic. Keep the same recovery
/// available without treating DNS errors or unrelated Git failures as a login issue.
struct GitAuthenticationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func matches(_ message: String) -> Bool {
        let value = message.lowercased()
        if value.contains("github authentication is unavailable")
            || value.contains("the workspace's github cli is not signed in") { return true }
        return value.components(separatedBy: .newlines).contains { line in
            line.contains("github.com") && [
                "fatal: could not read username for ", "fatal: could not read password for ",
                "fatal: authentication failed for ", "permission denied (publickey)"
            ].contains(where: line.contains)
        }
    }
}
