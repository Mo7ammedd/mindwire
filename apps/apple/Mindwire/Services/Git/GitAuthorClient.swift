import Foundation

@MainActor
protocol GitAuthorRemote {
    func load(_ context: GitAuthorContext?) async throws -> GitAuthorSettings
    func save(_ update: GitAuthorUpdate, context: GitAuthorContext?) async throws -> GitAuthorSettings
}

@MainActor
struct GitAuthorClient: GitAuthorRemote {
    let http: DaemonHTTP

    func load(_ context: GitAuthorContext? = nil) async throws -> GitAuthorSettings {
        try await http.decode("GET", endpoint(context))
    }

    func save(_ update: GitAuthorUpdate, context: GitAuthorContext? = nil) async throws -> GitAuthorSettings {
        var body: [String: Any] = ["scope": update.scope.rawValue, "identity": NSNull()]
        if let identity = update.identity {
            body["identity"] = ["name": identity.name, "email": identity.email]
        }
        if let id = update.requestId { body["requestId"] = id }
        if let revision = update.expectedRevision { body["expectedRevision"] = revision }
        return try await http.decode("PUT", endpoint(context), json: body)
    }

    private func endpoint(_ context: GitAuthorContext?) -> String {
        let base = "/workspace/git/identity"
        if let id = context?.projectId { return base + "?projectId=" + http.encQuery(id) }
        if let path = context?.path { return base + "?path=" + http.encQuery(path) }
        return base
    }
}
