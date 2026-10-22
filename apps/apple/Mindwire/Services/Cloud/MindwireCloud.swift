import Foundation
import OblienKit

/// Mindwire owns account and management requests, including runtime-token grants.
/// The SDK connects directly to its default workspace.oblien.com gateway with that computer JWT.
enum MindwireCloud {
    static let client = OblienClient(OblienConfiguration(
        auth: .bearerSession { forceRefresh in try await MindwireAPI.shared.token(forceRefresh: forceRefresh) },
        baseURL: URL(string: AppConstants.mindwireServicesBase + "/api/cloud/provider")!))

    static func workspace(_ id: String) -> WorkspaceHandle { client.workspace(id) }
    static func invalidateAllRuntimes() async {
        await client.workspaces.invalidateAllRuntimes()
    }
}
