import Foundation
import OblienKit

/// Mindwire owns account and management requests. Runtime traffic uses the
/// provider gateway through its Mindwire hostname and the existing computer JWT.
enum MindwireCloud {
    static let client = OblienClient(OblienConfiguration(
        auth: .bearerSession { forceRefresh in try await MindwireAPI.shared.token(forceRefresh: forceRefresh) },
        baseURL: URL(string: AppConstants.mindwireServicesBase + "/api/cloud/provider")!,
        runtimeURL: URL(string: "https://computers.mindwire.sh")!))

    static func workspace(_ id: String) -> WorkspaceHandle { client.workspace(id) }
    static func invalidateAllRuntimes() async {
        await client.workspaces.invalidateAllRuntimes()
    }
}
