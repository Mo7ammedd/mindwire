import Foundation

enum GitAuthorScope: String, Codable, CaseIterable, Identifiable {
    case repository, workspace
    case allWorkspaces = "all_workspaces"
    var id: String { rawValue }
    var title: String { t("git.identity.scope.\(rawValue)") }
    var help: String { t("git.identity.scope.\(rawValue).body") }
}

struct GitAuthorSettings: Codable, Equatable {
    var effective = GitIdentity()
    var repository: GitIdentity?
    var workspace: GitIdentity?
    var allWorkspaces: GitIdentity?
    var defaultRevision = ""

    func configured(_ scope: GitAuthorScope) -> GitIdentity? {
        switch scope {
        case .repository: repository
        case .workspace: workspace
        case .allWorkspaces: allWorkspaces
        }
    }
}

struct GitAuthorContext {
    var projectId: String?
    var path: String?
}

struct GitAuthorUpdate: Equatable {
    let scope: GitAuthorScope
    let identity: GitIdentity?
    var requestId: String?
    var expectedRevision: String?
}
