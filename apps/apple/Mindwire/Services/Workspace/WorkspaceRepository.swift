import CryptoKit
import Foundation
import OblienKit
import Observation

/// Cached checks/connections belong to these inputs, not just a workspace ID. Changing a server's
/// connection settings or the cloud account must create a new connection and recheck it.
struct WorkspaceConnectionContext: Equatable {
    let runtime: AgentRuntime
    let server: Connection?
    let accountID: Int?

    @MainActor init(_ workspace: Workspace, stores: Stores) {
        runtime = workspace.runtime
        server = workspace.runtime.serverId.flatMap { stores.connections.get($0) }
        accountID = workspace.runtime.isCloud ? OblienAuth.shared.user?.id : nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.runtime == rhs.runtime, lhs.accountID == rhs.accountID else { return false }
        if let left = lhs.server?.pairedComputer, let right = rhs.server?.pairedComputer {
            // Routes and discovery metadata change during normal recovery. The
            // shared SSH pool verifies them against the same pinned identity;
            // they must not invalidate an in-flight desktop or workspace read.
            return lhs.server?.id == rhs.server?.id && lhs.server?.workspace == rhs.server?.workspace
                && left.samePairing(as: right) && left.operatingSystem == right.operatingSystem
        }
        return lhs.server == rhs.server
    }
}

// MARK: - Adapter port

/// One backing destination for workspaces — Oblien Cloud, a self-hosted control plane, or any
/// future target. Each adapter owns a slice of the workspace space; the `WorkspaceRepository` fans
/// reads across every adapter and routes each write to the owning one. Add a destination by
/// registering another adapter — no UI or call-site changes.
protocol WorkspaceAdapter: AnyObject {
    /// Authentication belongs to the destination, not to local projects or the app as a whole.
    @MainActor var requiresSignIn: Bool { get }
    /// Does this adapter own (manage the lifecycle of) the given workspace?
    func owns(_ workspace: Workspace) -> Bool
    /// Best-known workspaces, served from memory / local store — instant, no I/O.
    @MainActor func current() -> [Workspace]
    /// Pull the latest state from the backing source into `current()`.
    func refresh() async throws
    /// Adopt a freshly-provisioned runtime as a workspace record (returns the canonical workspace), or
    /// nil if this adapter doesn't own that runtime.
    func adopt(name: String, runtime: AgentRuntime, spec: WorkspaceSpec?) async -> Workspace?
    func rename(_ id: String, to name: String) async
    func delete(_ id: String) async throws
    /// A missing cache row is not proof of deletion. Only an authoritative lookup can confirm it.
    func confirmsDeletion(_ id: String) async -> Bool
}

extension WorkspaceAdapter {
    @MainActor var requiresSignIn: Bool { false }
    func confirmsDeletion(_ id: String) async -> Bool { false }
}

// MARK: - Local adapter (self-hosted / on-device)

/// Self-hosted workspaces persisted on device via the swappable `ListStore`. Owns only server
/// runtimes — cloud lives on Oblien (`CloudWorkspaceAdapter`).
final class LocalWorkspaceAdapter: WorkspaceAdapter {
    private let stores: Stores

    init(stores: Stores) {
        self.stores = stores
    }

    func owns(_ workspace: Workspace) -> Bool { workspace.runtime.isServer && workspace.runtime.sandbox == nil }
    func current() -> [Workspace] { stores.workspaces.list().filter(owns) }
    func refresh() async {}  // the local store is already the source of truth

    func adopt(name: String, runtime: AgentRuntime, spec: WorkspaceSpec?) async -> Workspace? {
        guard runtime.isServer, runtime.sandbox == nil else { return nil }
        return stores.createWorkspace(name: name, runtime: runtime, spec: spec)
    }
    func rename(_ id: String, to name: String) async { stores.renameWorkspace(id, name: name) }
    func delete(_ id: String) async { stores.workspaces.remove(id) }
}

// MARK: - Cloud adapter (Oblien)

/// Oblien owns this inventory. A session/account-scoped snapshot restores display metadata on
/// launch while the first live check runs. It never persists a claim about service or VM health.
@MainActor
final class CloudWorkspaceAdapter: WorkspaceAdapter {
    private struct Context: Codable, Equatable {
        let accountID: Int
        let sessionFingerprint: String?
    }
    private struct Snapshot: Codable {
        let context: Context
        let workspaces: [Workspace]
    }

    private var cache: [Workspace] = []
    private var cacheContext: Context?
    private var cacheGeneration = 0
    private let auth: OblienAuth
    private let defaults: UserDefaults
    private let sessionToken: () -> String?
    private let loadWorkspaces: () async throws -> [OblienKit.Workspace]
    private let lookupWorkspace: (String) async throws -> OblienKit.Workspace
    private let removeWorkspace: (String) async throws -> Void

    init(auth: OblienAuth = .shared,
         defaults: UserDefaults = .standard,
         sessionToken: @escaping () -> String? = SessionToken.get,
         lookupWorkspace: @escaping (String) async throws -> OblienKit.Workspace = {
             try await OblienCloud.client.workspaces.get($0)
         },
         removeWorkspace: @escaping (String) async throws -> Void = {
             try await OblienCloud.client.workspaces.delete($0)
         },
         loadWorkspaces: @escaping () async throws -> [OblienKit.Workspace] = {
             try await OblienCloud.client.workspaces.list().workspaces
         }) {
        self.auth = auth
        self.defaults = defaults
        self.sessionToken = sessionToken
        self.loadWorkspaces = loadWorkspaces
        self.lookupWorkspace = lookupWorkspace
        self.removeWorkspace = removeWorkspace
        if !auth.isSignedOut,
           let fingerprint = Self.fingerprint(sessionToken()),
           let data = defaults.data(forKey: StorageKey.cloudWorkspaceCache),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           snapshot.context.sessionFingerprint == fingerprint,
           !auth.authenticated || snapshot.context.accountID == auth.user?.id {
            cacheContext = snapshot.context
            cache = snapshot.workspaces.filter(\.isCloud)
        }
    }

    nonisolated func owns(_ workspace: Workspace) -> Bool { workspace.runtime.isCloud }
    var requiresSignIn: Bool { auth.isSignedOut }
    func current() -> [Workspace] {
        guard !requiresSignIn,
              !auth.authenticated || auth.user?.id == cacheContext?.accountID else { return [] }
        return cache
    }

    func confirmsDeletion(_ id: String) async -> Bool {
        guard let context = context() else { return false }
        let generation = cacheGeneration
        do {
            let found = try await lookupWorkspace(id)
            guard context == self.context(), generation == cacheGeneration else { return false }
            // List pagination/filtering must not make a still-accessible workspace disappear.
            if !cache.contains(where: { $0.id == id }) {
                cache.append(Self.workspace(from: found))
                cacheContext = context
                cacheGeneration &+= 1
                persist()
            }
            return false
        } catch let error as OblienError where error.status == 404 {
            guard context == self.context(), generation == cacheGeneration else { return false }
            cache.removeAll { $0.id == id }
            cacheGeneration &+= 1
            persist()
            return true
        } catch { return false }
    }

    func refresh() async throws {
        guard try await auth.check(), let context = context() else { clearCache(); return }
        if cacheContext != context {
            clearCache()
            cacheContext = context
        }
        let generation = cacheGeneration
        do {
            let list = try await loadWorkspaces()
            try Task.checkCancellation()
            guard context == self.context() else { throw CancellationError() }
            // A list started before a successful deletion must not resurrect that workspace.
            guard generation == cacheGeneration else { return }
            cache = list.map(Self.workspace(from:))
            persist()
            APILog.note("workspaces.list: \(list.count) cloud workspace(es)")
        } catch {
            APILog.note("workspaces.list failed: \(error.localizedDescription)")
            throw error // Keep the last good cache; callers can offer a retry.
        }
    }

    func adopt(name: String, runtime: AgentRuntime, spec: WorkspaceSpec?) async -> Workspace? {
        guard case .cloud(let wid?) = runtime,
              (try? await auth.check()) == true, let context = context() else { return nil }
        try? await refresh()  // the workspace already exists remotely; surface it
        guard context == self.context() else { return nil }
        if let found = current().first(where: { $0.id == wid }) { return found }
        // The list can lag a beat right after create — synthesize from what we already know.
        let workspace = Workspace(id: wid, name: name.isEmpty ? "Oblien Cloud" : name,
                       runtime: runtime, spec: spec, createdAt: isoNow(), lastUsedAt: nil)
        cache.append(workspace)
        cacheContext = context
        cacheGeneration &+= 1
        persist()
        return workspace
    }

    func rename(_ id: String, to name: String) async {
        try? await OblienCloud.client.workspaces.update(id, WorkspaceUpdateParams(name: name))
        try? await refresh()
    }
    func delete(_ id: String) async throws {
        guard try await auth.check(), let context = context() else { throw CancellationError() }
        do {
            try await removeWorkspace(id)
        } catch let error as OblienError where error.status == 404 {
            // Already deleted elsewhere: the requested end state has been reached.
        }
        guard context == self.context() else { throw CancellationError() }
        cache.removeAll { $0.id == id }
        cacheGeneration &+= 1
        persist()
    }

    private func clearCache() {
        cache = []
        cacheContext = nil
        cacheGeneration &+= 1
        defaults.removeObject(forKey: StorageKey.cloudWorkspaceCache)
    }

    private func context() -> Context? {
        guard auth.authenticated, let accountID = auth.user?.id else { return nil }
        return Context(accountID: accountID, sessionFingerprint: Self.fingerprint(sessionToken()))
    }

    private func persist() {
        guard let context = cacheContext, context.sessionFingerprint != nil,
              let data = try? JSONEncoder().encode(Snapshot(context: context, workspaces: cache)) else { return }
        defaults.set(data, forKey: StorageKey.cloudWorkspaceCache)
    }

    private static func fingerprint(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        // Keep the actual credential in Keychain; the display cache stores only its fingerprint.
        return Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString()
    }

    private static func workspace(from w: OblienKit.Workspace) -> Workspace {
        let spec = w.resources.map {
            WorkspaceSpec(cpus: $0.cpus ?? 0, memoryMb: $0.memoryMb ?? 0,
                        diskMb: $0.diskSizeMb ?? 0, persistent: w.mode == .permanent)
        }
        let name = (w.name?.isEmpty == false) ? w.name! : "Oblien Cloud"
        return Workspace(id: w.id, name: name, runtime: .cloud(workspaceId: w.id),
                       spec: spec, createdAt: w.createdAt ?? isoNow(), lastUsedAt: w.updatedAt,
                       image: w.image)
    }
}

// MARK: - Repository facade

/// The single API the UI talks to for workspaces. It owns the adapters, merges their views, and
/// routes writes to the owning adapter — callers never touch an adapter, OblienKit, or the
/// persistence layer directly. New destination = new `WorkspaceAdapter` registered here.
@MainActor @Observable
final class WorkspaceRepository {
    static let shared = WorkspaceRepository()

    private let adapters: [WorkspaceAdapter]
    private let stores: Stores
    private(set) var revision = 0
    private(set) var hasRefreshed = false
    private(set) var isRefreshing = false
    private(set) var refreshError: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var freshness = RefreshState()
    @ObservationIgnored private let now: () -> Date
    private struct CachedModel {
        let context: WorkspaceConnectionContext
        let model: WorkspaceModel
    }
    @ObservationIgnored private var models: [String: CachedModel] = [:]
    private struct DesktopKey: Hashable { let workspaceId: String; let desktopId: String? }
    @ObservationIgnored private var desktops: [DesktopKey: (WorkspaceConnectionContext, DesktopModel)] = [:]
    private(set) var reconnectingComputers: Set<String> = []
    private(set) var computerReconnectMessages: [String: String] = [:]
    @ObservationIgnored private var computerReconnectTasks: [String: (id: UUID, code: String?, task: Task<Connection, Error>)] = [:]
    @ObservationIgnored private let resumeComputer: (PairedComputer, @escaping @MainActor @Sendable (String) -> Void) async throws -> ComputerPairingService.Result
    @ObservationIgnored private var recovery: ComputerRecoveryCoordinator?
    @ObservationIgnored private var restoreObserver: NSObjectProtocol?

    var computerRecovery: ComputerRecoveryCoordinator {
        if let recovery { return recovery }
        let coordinator = ComputerRecoveryCoordinator(connections: { [weak self] in self?.stores.connections.list() ?? [] },
            attempt: { [weak self] id in
                guard let self else { throw CancellationError() }
                _ = try await self.reconnectComputer(id, automatic: true)
            }, cancelAttempt: { [weak self] id in self?.cancelComputerReconnect(id, pauseAutomatic: false) })
        recovery = coordinator
        return coordinator
    }

    func desktopModel(for id: String, desktopId: String? = nil) -> DesktopModel? {
        guard let workspace = get(id) else { return nil }
        let context = WorkspaceConnectionContext(workspace, stores: stores)
        let key = DesktopKey(workspaceId: id, desktopId: desktopId)
        if let cached = desktops[key], cached.0 == context { return cached.1 }
        desktops[key]?.1.disconnect()
        let model = DesktopModel(workspace: workspace, stores: stores, desktopId: desktopId)
        desktops[key] = (context, model)
        return model
    }

    func supportsDesktop(_ id: String) -> Bool {
        guard let workspace = get(id) else { return false }
        return WorkspaceDesktopProviders.supports(workspace, stores: stores)
    }


    init(stores: Stores = .shared, adapters: [WorkspaceAdapter]? = nil, now: @escaping () -> Date = Date.init,
         resumeComputer: ((PairedComputer, @escaping @MainActor @Sendable (String) -> Void) async throws -> ComputerPairingService.Result)? = nil) {
        self.stores = stores
        self.now = now
        self.resumeComputer = resumeComputer ?? { try await ComputerPairingService.resume($0, stores: stores, onStatus: $1) }
        // Legacy cloud rows have no account scope; only the cloud adapter's scoped cache is valid.
        stores.purgePersistedCloudWorkspaces()
        self.adapters = adapters ?? [LocalWorkspaceAdapter(stores: stores), DockerWorkspaceAdapter(stores: stores),
                                     CloudWorkspaceAdapter(defaults: stores.defaults)]
        restoreObserver = NotificationCenter.default.addObserver(forName: .connectionLibraryRestored,
            object: stores, queue: .main) { [weak self] notification in
            let credentialConnections = Set(notification.userInfo?["credentialConnections"] as? [String] ?? [])
            Task { @MainActor in
                guard let self else { return }
                for (id, cached) in self.models {
                    guard let workspace = self.get(id),
                          !credentialConnections.contains(workspace.runtime.serverId ?? ""),
                          cached.context == WorkspaceConnectionContext(workspace, stores: stores) else {
                        self.discardModel(id)
                        continue
                    }
                }
                self.recovery?.synchronize()
                self.revision &+= 1
            }
        }
    }

    deinit { if let restoreObserver { NotificationCenter.default.removeObserver(restoreObserver) } }

    /// All workspaces across every destination, most-recent first.
    var all: [Workspace] {
        _ = revision // Adapter caches are not observable; publish changes through the repository.
        return adapters.filter { !$0.requiresSignIn }.flatMap { $0.current() }
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }

    func get(_ id: String) -> Workspace? { all.first { $0.id == id } }

    /// Profiles are a cache of the workspace's inventory, never independent destinations.
    /// Signed-out accounts and forgotten connections must not leave orphan agent cards.
    /// An offline workspace remains in its adapter's last good, account-scoped inventory.
    func agents(workspaceId: String? = nil) -> [Agent] {
        let workspaceIDs = Set(all.lazy.filter { workspaceId == nil || $0.id == workspaceId }.map(\.id))
        return stores.agentsSortedByRecency().filter { agent in
            guard let owner = agent.workspaceId else { return false }
            return workspaceIDs.contains(owner) && stores.isAgentAvailable(agent)
        }
    }

    var requiresSignIn: Bool { adapters.contains { $0.requiresSignIn } }

    /// Local workspace records resolve synchronously, even while signed out. An unresolved
    /// reference cannot be called unavailable until the cloud destination can check it.
    func requiresSignIn(for id: String) -> Bool {
        for adapter in adapters where adapter.current().contains(where: { $0.id == id }) {
            return adapter.requiresSignIn
        }
        return requiresSignIn
    }

    /// Navigation/foreground reuses recent checks. Explicit refresh always reaches the source.
    func refreshIfNeeded() async { await refresh(force: false) }
    func refresh() async { await refresh(force: true) }

    /// Pull-to-refresh on a list checks its service badges as well as the workspace inventory.
    func refreshChecks() async {
        await refresh()
        await stores.workspaceData.refreshAll(all, force: true)
    }

    private func refresh(force: Bool) async {
        if let refreshTask { await refreshTask.value; return }
        guard force || !freshness.isFresh(at: now()) else { return }
        let checkRevision = freshness.revision
        let task = Task { @MainActor in
            // Retain the ready UI during periodic revalidation; initial/manual checks show progress.
            isRefreshing = force || (!hasRefreshed && all.isEmpty)
            var failures: [String] = []
            for adapter in adapters {
                do { try await adapter.refresh() }
                catch { failures.append(error.localizedDescription) }
            }
            if failures.isEmpty {
                let referenced = Set(stores.projects.list().map(\.workspaceId) + stores.agents.list().compactMap(\.workspaceId))
                    .union(stores.workspaceData.projectOperations.keys)
                    .union(stores.preparation.pendingWorkspaceIDs)
                let missing = referenced.subtracting(all.map(\.id))
                for id in missing {
                    for adapter in adapters where await adapter.confirmsDeletion(id) {
                        for agent in stores.agents(forWorkspaceId: id) { DaemonManager.shared.discard(agent.id) }
                        stores.cascadeProjects(forWorkspaceId: id)
                        stores.workspaceData.forget(id)
                        break
                    }
                }
            }
            refreshError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            freshness.finish(success: failures.isEmpty, at: now(), revision: checkRevision)
            hasRefreshed = true
            revision &+= 1
            isRefreshing = false
            refreshTask = nil
            let workspaces = all
            for id in models.keys where !workspaces.contains(where: { $0.id == id }) { discardModel(id) }
            for key in desktops.keys where !workspaces.contains(where: { $0.id == key.workspaceId }) { desktops.removeValue(forKey: key)?.1.disconnect() }
            Task { await stores.workspaceData.refreshAll(workspaces) }
        }
        refreshTask = task
        await task.value
    }

    /// Surface a freshly-provisioned workspace via its owning adapter (persists self-hosted; for
    /// cloud the workspace already exists remotely, so this just returns the live record).
    @discardableResult
    func adopt(name: String, runtime: AgentRuntime, spec: WorkspaceSpec?) async -> Workspace? {
        for adapter in adapters {
            if let workspace = await adapter.adopt(name: name, runtime: runtime, spec: spec) {
                stores.preparation.enqueue(workspaceId: workspace.id)
                freshness.invalidate()
                revision &+= 1
                return workspace
            }
        }
        return nil
    }

    func rename(_ id: String, to name: String) async {
        guard let workspace = get(id) else { return }
        for adapter in adapters where adapter.owns(workspace) { await adapter.rename(id, to: name) }
        freshness.invalidate()
        revision &+= 1
    }

    func delete(_ id: String) async throws {
        guard let workspace = get(id) else { return }
        if let serverId = workspace.runtime.serverId, workspace.runtime.sandbox == nil,
           stores.connections.get(serverId)?.pairedComputer != nil {
            forgetConnection(serverId)
            return
        }
        for adapter in adapters where adapter.owns(workspace) { try await adapter.delete(id) }
        stores.cascadeProjects(forWorkspaceId: id)  // local projects/chats bound to it
        stores.workspaceData.forget(id)
        discardModel(id)
        freshness.invalidate()
        revision &+= 1
    }

    /// Forgetting a saved host is entirely local. It must work offline and must
    /// never delete native conversations, project metadata, files, or containers.
    func forgetConnection(_ serverId: String) {
        cancelComputerReconnect(serverId)
        recovery?.forget(serverId)
        let workspaces = stores.workspaces(forServerId: serverId)
        for workspace in workspaces {
            for agent in stores.agents(forWorkspaceId: workspace.id) {
                DaemonManager.shared.discard(agent.id, notifyRemote: false)
            }
            discardModel(workspace.id)
        }
        stores.deleteServer(serverId)
        for workspace in workspaces { stores.workspaceData.forget(workspace.id) }
        freshness.invalidate()
        revision &+= 1
    }

    func cancelComputerReconnect(_ serverId: String, pauseAutomatic: Bool = true) {
        computerReconnectTasks.removeValue(forKey: serverId)?.task.cancel()
        reconnectingComputers.remove(serverId)
        computerReconnectMessages[serverId] = nil
        if pauseAutomatic { recovery?.pause(serverId) }
    }

    /// Recovery entry points join one attempt. Without a code this only retries
    /// saved credentials; a fresh QR can repair a lost key with computer approval.
    @discardableResult
    func reconnectComputer(_ serverId: String, code: String? = nil, automatic: Bool = false) async throws -> Connection {
        if !automatic { recovery?.manualRetry(serverId) }
        if let pending = computerReconnectTasks[serverId] {
            if code == nil || code == pending.code { return try await pending.task.value }
            pending.task.cancel()
        }
        guard let connection = stores.connections.get(serverId), let saved = connection.pairedComputer else {
            throw ComputerConnectionError.notPaired
        }
        if let code {
            let parsed = try ComputerConnectionCode.parse(code)
            let fingerprint: String
            switch parsed {
            case .pairing(let invite): fingerprint = invite.fingerprint
            case .reconnect(let refresh): fingerprint = refresh.fingerprint
            }
            guard parsed.computerId == saved.computerId, fingerprint == saved.fingerprint else {
                throw ComputerConnectionError.identityChanged
            }
        }
        let id = UUID()
        reconnectingComputers.insert(serverId)
        computerReconnectMessages[serverId] = "Reconnecting…"
        let task = Task { @MainActor in
            defer {
                if computerReconnectTasks[serverId]?.id == id {
                    computerReconnectTasks[serverId] = nil
                    reconnectingComputers.remove(serverId)
                    computerReconnectMessages[serverId] = nil
                }
            }
            let result: ComputerPairingService.Result
            if let code {
                result = try await ComputerPairingService.pair(code, deviceName: "iPhone", stores: stores) { message in
                    if self.computerReconnectTasks[serverId]?.id == id { self.computerReconnectMessages[serverId] = message }
                }
            } else {
                result = try await resumeComputer(saved) { message in
                    if self.computerReconnectTasks[serverId]?.id == id { self.computerReconnectMessages[serverId] = message }
                }
            }
            try Task.checkCancellation()
            guard computerReconnectTasks[serverId]?.id == id,
                  stores.connections.get(serverId)?.pairedComputer?.samePairing(as: saved) == true else {
                throw CancellationError()
            }
            let updated = stores.savePairedComputer(result, name: connection.name)
            connectionRecovered(updated, health: result.health)
            recovery?.succeeded(serverId)
            return updated
        }
        computerReconnectTasks[serverId] = (id, code, task)
        do { return try await task.value }
        catch {
            if !automatic { recovery?.failed(serverId, error: error) }
            throw error
        }
    }

    func connectionRecovered(_ connection: Connection, health: DaemonHealth? = nil) {
        let workspaces = stores.workspaces(forServerId: connection.id)
        for workspace in workspaces {
            discardModel(workspace.id)
            stores.workspaceData.connectionRecovered(workspace.id, health: health)
        }
        revision &+= 1
    }

    /// The repository owns control models, so pushing another screen never destroys a good check
    /// or disconnects a backend shared by another view of the same workspace.
    func model(for workspace: Workspace) -> WorkspaceModel {
        let context = WorkspaceConnectionContext(workspace, stores: stores)
        if let cached = models[workspace.id], cached.context == context { return cached.model }
        discardModel(workspace.id)
        let model = WorkspaceModel(backend: BackendFactory.make(forRuntime: workspace.runtime, stores: stores),
                                   now: now, onChange: { [weak self] in
            self?.stores.workspaceData.invalidateChecks(workspace.id)
            self?.freshness.invalidate()
        }, workspaceId: workspace.id, verifyService: { [weak self] in
            guard let self, get(workspace.id) != nil else { return true }
            await stores.workspaceData.refresh(workspace)
            return DaemonWorkCoordinator.shared.states[.init(workspaceId: workspace.id)]?.reachable == true
        }, startService: { [weak self] in
            try? await self?.stores.workspaceData.startDaemon(workspaceId: workspace.id)
        })
        models[workspace.id] = CachedModel(context: context, model: model)
        return model
    }

    private func discardModel(_ id: String) {
        for key in desktops.keys where key.workspaceId == id { desktops.removeValue(forKey: key)?.1.disconnect() }
        if let cached = models.removeValue(forKey: id) { Task { await cached.model.dispose() } }
    }
}
