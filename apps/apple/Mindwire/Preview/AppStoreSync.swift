#if DEBUG
import Foundation

/// UI fixtures exercise the production sync service with a disposable cloud.
/// Opening Settings in a screenshot/test never touches a real Apple Account.
@MainActor final class StoreConnectionCloud: ConnectionCloud {
    private var values: [String: ConnectionCloudRecord] = [:]
    private var pending: Set<String> = []
    private var receive: (@MainActor (ConnectionCloudEvent) -> Void)?
    private var record: (@MainActor (String) -> ConnectionCloudRecord?)?
    func accountID() async throws -> String { "preview-apple-account" }
    func hasBackup() async throws -> Bool { values["settings"] != nil }
    func start(state: Data?, receive: @escaping @MainActor (ConnectionCloudEvent) -> Void,
               record: @escaping @MainActor (String) -> ConnectionCloudRecord?) throws {
        self.receive = receive; self.record = record
    }
    func schedule(_ ids: Set<String>) { pending.formUnion(ids) }
    func fetch() async throws { receive?(.received(Array(values.values))) }
    func send() async throws {
        var saved: [ConnectionCloudRecord] = []
        for id in pending { if let value = record?(id) { values[id] = value; saved.append(value) } }
        pending.removeAll()
        if !saved.isEmpty { receive?(.saved(saved)) }
    }
    func stop() async { receive = nil; record = nil }
    func erase() async throws { values.removeAll() }
}

final class StoreConnectionSecrets: ConnectionSyncSecrets {
    private var values: [String: String] = [:]
    private var cloud: [String: String] = [:]
    func local(_ key: String) -> String? { values[key] }
    @discardableResult func setLocal(_ value: String, key: String) -> Bool { values[key] = value; return true }
    @discardableResult func removeLocal(_ key: String) -> Bool { values[key] = nil; return true }
    func synced(_ reference: String, account: String) -> String? { cloud[account + ":" + reference] }
    func setSynced(_ value: String, reference: String, account: String) throws { cloud[account + ":" + reference] = value }
    func removeSynced(reference: String, account: String) throws { cloud[account + ":" + reference] = nil }
    func removeAllSynced(account: String) throws { cloud = cloud.filter { !$0.key.hasPrefix(account + ":") } }
}
#endif
