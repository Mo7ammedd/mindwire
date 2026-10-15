import Foundation
import Observation

/// One user-selected default for this app's connected workspaces. Each daemon
/// owns its applied copy and its narrower overrides. Delivery is acknowledged,
/// persisted and resumed by the app lifecycle, independently of any open form.
@MainActor @Observable
final class GitAuthorDefaults {
    struct Preference: Codable, Equatable {
        let id: String
        let identity: GitIdentity?
    }
    struct Connection {
        let registryId: String
        let remote: any GitAuthorRemote
    }
    private struct Delivery: Codable {
        let preferenceId: String
        let registryId: String
        let expectedRevision: String
    }
    private struct Receipt: Codable {
        let preferenceId: String
        let registryId: String
    }
    private struct Cache: Codable {
        var preference: Preference?
        var deliveries: [String: Delivery] = [:]
        var receipts: [String: Receipt] = [:]
    }

    private(set) var preference: Preference?
    private(set) var active: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connect: (String) async throws -> Connection
    @ObservationIgnored private let knownIdentity: (String) -> String?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var deliveries: [String: Delivery]
    @ObservationIgnored private var receipts: [String: Receipt]
    @ObservationIgnored private var jobs: [String: Task<Bool, Never>] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var generations: [String: Int] = [:]
    private static let cacheKey = "mindwire:git-author-default:v1"

    init(stores: Stores, now: @escaping () -> Date = Date.init,
         knownIdentity: ((String) -> String?)? = nil,
         connect: ((String) async throws -> Connection)? = nil) {
        defaults = stores.defaults
        self.now = now
        self.knownIdentity = knownIdentity ?? { [weak stores] in stores?.workspaceData.identity(workspaceId: $0) }
        self.connect = connect ?? { [weak stores] id in
            guard let stores else { throw CancellationError() }
            let http = try await stores.workspaceData.gitIdentityHTTP(workspaceId: id)
            guard let registry = stores.workspaceData.identity(workspaceId: id) else { throw WorkspaceRegistryError.missing }
            return Connection(registryId: registry, remote: GitAuthorClient(http: http))
        }
        let cache = defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        preference = cache.preference
        deliveries = cache.deliveries
        receipts = cache.receipts
    }

    func set(_ identity: GitIdentity?) {
        preference = Preference(id: UUID().uuidString, identity: identity?.normalized)
        deliveries.removeAll()
        errors.removeAll()
        retryAfter.removeAll()
        persist()
    }

    func isPending(_ workspaceId: String) -> Bool {
        _ = revision
        guard let preference else { return false }
        guard let receipt = receipts[workspaceId], receipt.preferenceId == preference.id else { return true }
        if let identity = knownIdentity(workspaceId) { return receipt.registryId != identity }
        return true
    }

    func reconcile(_ workspaces: [Workspace]) {
        guard preference != nil else { return }
        let pending = workspaces.filter { isPending($0.id) && jobs[$0.id] == nil
            && (retryAfter[$0.id].map { now() >= $0 } ?? true) }
        for workspace in pending.prefix(max(0, 3 - active.count)) {
            Task { await synchronize(workspace.id) }
        }
    }

    @discardableResult
    func synchronize(_ workspaceId: String) async -> Bool {
        guard let desired = preference else { return true }
        if let task = jobs[workspaceId] {
            return await task.value
        }
        if !isPending(workspaceId) { return true }
        active.insert(workspaceId)
        let generation = generations[workspaceId, default: 0]
        let task = Task { () -> Bool in
            defer { active.remove(workspaceId); jobs[workspaceId] = nil }
            do {
                let connection = try await connect(workspaceId)
                guard desired == preference, !Task.isCancelled,
                      generation == generations[workspaceId, default: 0] else { return false }
                let receipt = receipts[workspaceId]
                if receipt?.preferenceId == desired.id && receipt?.registryId == connection.registryId { return true }
                var delivery = deliveries[workspaceId]
                if delivery?.preferenceId != desired.id || delivery?.registryId != connection.registryId {
                    let state = try await connection.remote.load(nil)
                    guard desired == preference, !Task.isCancelled,
                          generation == generations[workspaceId, default: 0] else { return false }
                    delivery = Delivery(preferenceId: desired.id, registryId: connection.registryId,
                                        expectedRevision: state.defaultRevision)
                    deliveries[workspaceId] = delivery
                    persist()
                }
                guard let delivery else { return false }
                let result = try await connection.remote.save(.init(scope: .allWorkspaces, identity: desired.identity,
                    requestId: desired.id, expectedRevision: delivery.expectedRevision), context: nil)
                guard result.defaultRevision == desired.id, result.allWorkspaces == desired.identity else {
                    throw BackendError.message(t("git.identity.notAcknowledged"))
                }
                guard desired == preference, !Task.isCancelled,
                      generation == generations[workspaceId, default: 0] else { return false }
                receipts[workspaceId] = Receipt(preferenceId: desired.id, registryId: connection.registryId)
                deliveries[workspaceId] = nil
                errors[workspaceId] = nil
                retryAfter[workspaceId] = nil
                persist()
                return true
            } catch {
                guard desired == preference, !Task.isCancelled,
                      generation == generations[workspaceId, default: 0] else { return false }
                errors[workspaceId] = error.localizedDescription
                retryAfter[workspaceId] = now().addingTimeInterval(30)
                persist()
                return false
            }
        }
        jobs[workspaceId] = task
        return await task.value
    }

    func forget(_ workspaceId: String) {
        generations[workspaceId, default: 0] += 1
        jobs[workspaceId]?.cancel()
        deliveries[workspaceId] = nil
        receipts[workspaceId] = nil
        errors[workspaceId] = nil
        retryAfter[workspaceId] = nil
        persist()
    }

    private func persist() {
        let cache = Cache(preference: preference, deliveries: deliveries, receipts: receipts)
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey) }
        revision &+= 1
    }
}
