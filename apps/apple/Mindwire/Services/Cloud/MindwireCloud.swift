import Foundation
import CryptoKit
import OblienKit

/// The SDK remains an internal transport. Computer apps use isolated Mindwire
/// origins; their JavaScript and cookies cannot access the account control plane.
enum MindwireCloud {
    static let client = makeClient(runtime: URL(string: "https://computers.mindwire.sh/api/cloud/runtime")!)
    private static let lock = NSLock()
    private static var computers: [String: OblienClient] = [:]

    static func client(for workspaceId: String) -> OblienClient {
        lock.withLock {
            if let existing = computers[workspaceId] { return existing }
            let host = SHA256.hash(data: Data(workspaceId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40)
            let value = makeClient(runtime: URL(string: "https://\(host).computers.mindwire.sh/api/cloud/runtime")!)
            computers[workspaceId] = value
            return value
        }
    }
    static func workspace(_ id: String) -> WorkspaceHandle { client(for: id).workspace(id) }
    static func invalidateAllRuntimes() async {
        let clients = lock.withLock { Array(computers.values) + [client] }
        for value in clients { await value.workspaces.invalidateAllRuntimes() }
        lock.withLock { computers.removeAll() }
    }
    private static func makeClient(runtime: URL) -> OblienClient {
        OblienClient(OblienConfiguration(
            auth: .bearerSession { forceRefresh in try await MindwireAPI.shared.token(forceRefresh: forceRefresh) },
            baseURL: URL(string: AppConstants.mindwireServicesBase + "/api/cloud/provider")!, runtimeURL: runtime))
    }
}
