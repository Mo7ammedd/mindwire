import Foundation

/// Only cloud workspaces have an Oblien workspace ID. Paired computers and SSH environments
/// use a delegated user send token with their own workspace channel; never an account credential.
struct WorkspaceNotificationScope: Sendable, Equatable {
    let workspaceID: String
    let cloudWorkspaceID: String?

    init?(workspaceID: String, runtime: AgentRuntime) {
        guard !workspaceID.isEmpty else { return nil }
        self.workspaceID = workspaceID
        switch runtime {
        case .cloud(let id):
            guard let id, !id.isEmpty else { return nil }
            cloudWorkspaceID = id
        case .server, .container:
            cloudWorkspaceID = nil
        }
    }

    // Retain the cloud cache key while isolating generic credentials from workspace-bound ones.
    var credentialID: String { cloudWorkspaceID ?? "remote-\(workspaceID)" }
}

/// Installs a send-only credential; Mindwire owns the device registry and delivery.
@MainActor
enum WorkspaceNotify {
    static var sendURL: String { AppConstants.mindwireServicesBase + "/api/notifications/send" }

    static func sendToken(scope: WorkspaceNotificationScope) async -> String? {
        guard await MindwireAuth.shared.ensure(), let userID = MindwireAuth.shared.user?.id else { return nil }
        return await WorkspaceNotificationTokens.shared.token(scope: scope, accountID: userID,
                                                               deviceID: DeviceID.current())
    }
}

/// Credentials are scoped to account, workspace, and installation. A stable per-install tag avoids
/// another phone rotating the same secret and later restoring a stale cached credential to the daemon.
/// Validation discovers revoked/rotated credentials; concurrent agent sessions share one mint.
actor WorkspaceNotificationTokens {
    static let shared = WorkspaceNotificationTokens()
    private struct Credential: Codable {
        let id: Int
        let secret: String
    }
    private let read: @Sendable (String) -> String?
    private let write: @Sendable (String, String) -> Void
    private let list: @Sendable (String?) async throws -> [NotificationSendToken]
    private let mint: @Sendable (WorkspaceNotificationScope, String) async throws -> NotificationSendToken
    private var pending: [String: Task<String?, Never>] = [:]

    init(read: @escaping @Sendable (String) -> String? = { Keychain.get($0) },
         write: @escaping @Sendable (String, String) -> Void = { key, value in _ = Keychain.set(value, for: key) },
         list: @escaping @Sendable (String?) async throws -> [NotificationSendToken] = {
             try await NotificationsAPI().listSendTokens(workspaceID: $0)
         },
         mint: @escaping @Sendable (WorkspaceNotificationScope, String) async throws -> NotificationSendToken = { scope, tag in
             try await NotificationsAPI().createSendToken(workspaceID: scope.cloudWorkspaceID, tag: tag,
                                                                        name: "Mindwire", metadata: ["channel": scope.workspaceID])
         }) {
        self.read = read; self.write = write; self.list = list; self.mint = mint
    }

    func token(scope: WorkspaceNotificationScope, accountID: String, deviceID: String) async -> String? {
        // Keep the cache key through the service migration: imported token ids
        // and hashes remain valid, so existing daemons need no secret rotation.
        let key = "oblien.notify.v2.\(accountID).\(scope.credentialID).\(deviceID)"
        if let task = pending[key] { return await task.value }
        let task = Task { await self.resolve(key: key, scope: scope, deviceID: deviceID) }
        pending[key] = task
        defer { pending[key] = nil }
        return await task.value
    }

    private func resolve(key: String, scope: WorkspaceNotificationScope, deviceID: String) async -> String? {
        do {
            if let value = read(key), let bytes = value.data(using: .utf8),
               let cached = try? JSONDecoder().decode(Credential.self, from: bytes) {
                let tokens = try await list(scope.cloudWorkspaceID)
                if tokens.contains(where: {
                    $0.id == cached.id && $0.status == "active"
                        && ($0.tokenPrefix.map { cached.secret.hasPrefix($0) } ?? true)
                }) { return cached.secret }
            }
            let token = try await mint(scope, "mindwire-\(scope.credentialID)-\(deviceID)")
            guard let secret = token.token, !secret.isEmpty else { return nil }
            let credential = Credential(id: token.id, secret: secret)
            if let bytes = try? JSONEncoder().encode(credential), let value = String(data: bytes, encoding: .utf8) {
                write(key, value)
            }
            return secret
        } catch {
            APILog.note("notify: credential setup failed (\(scope.workspaceID)) — \(error.localizedDescription.oneLine())")
            return nil
        }
    }
}
