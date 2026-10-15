import Foundation
import OblienKit

/// The app's shared Oblien SDK client. It authenticates with the app's anonymous session
/// token (minted via `OblienAPI` / `POST /auth/token`) using the SDK's `.bearerSession` auth,
/// so the existing mint + Keychain + 401-refresh flow is preserved while every workspace /
/// runtime call goes through the typed SDK. Swap the `auth` case to adopt API keys or scoped
/// tokens later with no call-site changes.
enum OblienCloud {
    static let client = OblienClient(
        OblienConfiguration(
            auth: .bearerSession { forceRefresh in
                try await OblienAPI.shared.token(forceRefresh: forceRefresh)
            },
            baseURL: URL(string: AppConstants.oblienAPIBase) ?? URL(string: "https://api.oblien.com")!,
            runtimeURL: URL(string: AppConstants.oblienRuntimeBase) ?? URL(string: "https://workspace.oblien.com")!
        )
    )
}

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
        case .local, .server, .container:
            cloudWorkspaceID = nil
        }
    }

    // Retain the cloud cache key while isolating generic credentials from workspace-bound ones.
    var credentialID: String { cloudWorkspaceID ?? "remote-\(workspaceID)" }
}

/// Installs a send-only credential; device tokens remain in Oblien's registry.
@MainActor
enum WorkspaceNotify {
    static var sendURL: String { AppConstants.oblienAPIBase + "/notifications/send" }

    static func sendToken(scope: WorkspaceNotificationScope) async -> String? {
        guard await OblienAuth.shared.ensure(), let userID = OblienAuth.shared.user?.id else { return nil }
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
    private let list: @Sendable (String?) async throws -> [WorkspaceSendToken]
    private let mint: @Sendable (WorkspaceNotificationScope, String) async throws -> WorkspaceSendToken
    private var pending: [String: Task<String?, Never>] = [:]

    init(read: @escaping @Sendable (String) -> String? = { Keychain.get($0) },
         write: @escaping @Sendable (String, String) -> Void = { key, value in _ = Keychain.set(value, for: key) },
         list: @escaping @Sendable (String?) async throws -> [WorkspaceSendToken] = {
             try await OblienCloud.client.notifications.listSendTokens(workspaceId: $0)
         },
         mint: @escaping @Sendable (WorkspaceNotificationScope, String) async throws -> WorkspaceSendToken = { scope, tag in
             try await OblienCloud.client.notifications.createSendToken(workspaceId: scope.cloudWorkspaceID, tag: tag,
                                                                        name: "Mindwire", metadata: ["channel": scope.workspaceID])
         }) {
        self.read = read; self.write = write; self.list = list; self.mint = mint
    }

    func token(scope: WorkspaceNotificationScope, accountID: Int, deviceID: String) async -> String? {
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
