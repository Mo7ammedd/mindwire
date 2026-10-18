import Foundation
import Observation

/// One queue per app, keyed by workspace rather than screen or agent persona.
/// Automatic updates wait for idle. Explicit updates authorize a service restart.
@MainActor @Observable
final class ServiceUpdateScheduler {
    private(set) var active: Set<String> = []
    private(set) var requested: Set<String>
    private(set) var checkingRelease = false
    private(set) var checkingWorkspaces: Set<String> = []
    private(set) var checkingUpdates = false
    private(set) var updatingAll = false
    private(set) var latestVersion: String?
    private(set) var releaseCheckedAt: Date?
    private(set) var releaseCheckError: String?
    @ObservationIgnored private weak var stores: Stores?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let coordinator: DaemonWorkCoordinator
    @ObservationIgnored private let canResolve: @MainActor (String) -> Bool
    @ObservationIgnored private let prepare: @MainActor (String) async throws -> Void
    @ObservationIgnored private let update: @MainActor (String, Bool, String?) async throws -> Void
    @ObservationIgnored private let observeUpdate: @MainActor (String) async throws -> Void
    @ObservationIgnored private let fetchCatalog: @MainActor () async throws -> DaemonCatalog
    @ObservationIgnored private let readWorkspace: @MainActor (Workspace) async -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var releaseCheck: Task<Bool, Never>?
    @ObservationIgnored private var workspaceChecks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var checkBatch: Task<Bool, Never>?
    @ObservationIgnored private var checkRequests: [String: Workspace] = [:]
    @ObservationIgnored private var updateBatch: Task<Bool, Never>?
    @ObservationIgnored private var updateRequests: [String: Workspace] = [:]
    @ObservationIgnored private var operations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var observations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var releaseAttemptedAt: Date?
    private static let requestsKey = "mindwire:pending-service-updates:v1"

    private enum Operation {
        case setup
        case update(automatic: Bool)
    }

    var automaticUpdates: Bool {
        defaults.object(forKey: StorageKey.automaticServiceUpdates) as? Bool ?? true
    }

    var checking: Bool { checkingUpdates || checkingRelease || !checkingWorkspaces.isEmpty }
    var busy: Bool { checking || updatingAll || !active.isEmpty }

    func work(for workspaceId: String) -> DaemonWorkState? {
        coordinator.states[.init(workspaceId: workspaceId)]
    }
    var waitingCount: Int {
        let waiting = coordinator.states.compactMap { key, state in
            key.agentType == nil && state.updateWaiting ? key.workspaceId : nil
        }
        return requested.union(waiting).subtracting(active).count
    }

    init(stores: Stores, coordinator: DaemonWorkCoordinator? = nil,
         canResolve: (@MainActor (String) -> Bool)? = nil,
         now: @escaping () -> Date = Date.init,
         prepare: (@MainActor (String) async throws -> Void)? = nil,
         update: (@MainActor (String, Bool, String?) async throws -> Void)? = nil,
         observeUpdate: (@MainActor (String) async throws -> Void)? = nil,
         fetchCatalog: @escaping @MainActor () async throws -> DaemonCatalog = {
             try await ReleaseCatalog.shared.load(maxAge: 0, allowStale: false)
         },
         readWorkspace: (@MainActor (Workspace) async -> Void)? = nil) {
        self.stores = stores
        defaults = stores.defaults
        requested = Set(defaults.stringArray(forKey: Self.requestsKey) ?? [])
        self.coordinator = coordinator ?? .shared
        self.canResolve = canResolve ?? { WorkspaceRepository.shared.get($0) != nil }
        self.now = now
        self.fetchCatalog = fetchCatalog
        self.readWorkspace = readWorkspace ?? { [weak stores] workspace in
            await stores?.workspaceData.refresh(workspace)
        }
        self.prepare = prepare ?? { [weak stores] id in
            guard let stores else { throw CancellationError() }
            try await stores.workspaceData.prepareDaemon(workspaceId: id)
        }
        self.update = update ?? { [weak stores] id, automatic, target in
            guard let stores else { throw CancellationError() }
            try await stores.workspaceData.updateDaemon(workspaceId: id, automatic: automatic, target: target)
        }
        self.observeUpdate = observeUpdate ?? { [weak stores] id in
            guard let stores else { throw CancellationError() }
            try await stores.workspaceData.observeDaemonUpdate(workspaceId: id)
        }
    }

    /// One release request on each app launch, then at most every five minutes while
    /// active. Persisted picker metadata is useful offline, but never proves a new check.
    @discardableResult
    func refreshRelease(force: Bool = false) async -> Bool {
        if let releaseCheck { return await releaseCheck.value }
        if !force, let attempted = releaseAttemptedAt {
            let age = now().timeIntervalSince(attempted)
            if age >= 0, age < (releaseCheckError == nil ? 300 : 60) {
                return releaseCheckError == nil && latestVersion != nil
            }
        }
        checkingRelease = true
        releaseAttemptedAt = now()
        let task = Task {
            defer { releaseCheck = nil; checkingRelease = false }
            do {
                let catalog = try await fetchCatalog()
                if latestVersion != catalog.version { retryAfter.removeAll() }
                latestVersion = catalog.version
                releaseCheckedAt = now()
                releaseCheckError = nil
                coordinator.recordLatestRelease(catalog.version)
                return true
            } catch {
                releaseCheckError = t("workspace.daemon.checkUpdatesFailed")
                APILog.note("Service release check: \(error.localizedDescription.oneLine())")
                return false
            }
        }
        releaseCheck = task
        return await task.value
    }

    /// Explicit controls check the release and installed versions without starting setup.
    /// Concurrent screens join the same reads; the work outlives the initiating view.
    @discardableResult
    func checkUpdates(_ workspaces: [Workspace]) async -> Bool {
        if let updateBatch {
            let uncovered = workspaces.filter { updateRequests[$0.id] == nil }
            let result = await updateBatch.value
            return uncovered.isEmpty ? result : await performChecks(uncovered) && result
        }
        return await performChecks(workspaces)
    }

    /// Keep the release and workspace preflight under one lock, including the interval
    /// after the release request finishes while a slower workspace is still being read.
    private func performChecks(_ workspaces: [Workspace]) async -> Bool {
        for workspace in workspaces { checkRequests[workspace.id] = workspace }
        if let checkBatch { return await checkBatch.value }
        checkingUpdates = true
        let task = Task {
            defer { checkBatch = nil; checkingUpdates = false; checkRequests.removeAll() }
            let release = await refreshRelease(force: true)
            var checked: Set<String> = []
            while true {
                let next = checkRequests.values.filter { !checked.contains($0.id) }
                if next.isEmpty { return release }
                checked.formUnion(next.map(\.id))
                await checkInstalledVersions(next)
            }
        }
        checkBatch = task
        return await task.value
    }

    private func checkInstalledVersions(_ workspaces: [Workspace]) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, workspace) in workspaces.enumerated() {
                if index >= 3 { await group.next() }
                group.addTask { await self.checkWorkspace(workspace) }
            }
        }
    }

    /// Manual intent also works with automatic updates disabled. Offline/stopped services
    /// stay queued until reachable; online services restart under one exclusive lease.
    @discardableResult
    func updateAll(_ workspaces: [Workspace]) async -> Bool {
        // Local service ownership stays with this app / the existing computer CLI.
        for workspace in workspaces where !workspace.runtime.isLocal { updateRequests[workspace.id] = workspace }
        if let updateBatch { return await updateBatch.value }
        updatingAll = true
        let task = Task {
            defer { updateBatch = nil; updatingAll = false; updateRequests.removeAll() }
            var checked = Set(updateRequests.keys)
            var submitted: Set<String> = []
            guard await performChecks(Array(updateRequests.values)) else { return false }
            while true {
                let next = updateRequests.values.filter { !checked.contains($0.id) }
                if !next.isEmpty {
                    checked.formUnion(next.map(\.id))
                    await checkInstalledVersions(next)
                }
                for id in checked.subtracting(submitted) {
                    submitted.insert(id)
                    guard updateRequests[id] != nil, canResolve(id), let state = work(for: id),
                          state.installedVersion != nil, state.updateAvailable else { continue }
                    enqueue(workspaceId: id)
                }
                // Offline/busy requests remain queued, but do not hold the UI open. Live
                // installs and verification stay in this same batch until they finish.
                if let pending = operations.first(where: { updateRequests[$0.key] != nil })?.value {
                    await pending.value
                } else if next.isEmpty {
                    return true
                }
            }
        }
        updateBatch = task
        return await task.value
    }

    private func checkWorkspace(_ workspace: Workspace) async {
        if let operation = operations[workspace.id] { await operation.value; return }
        if let pending = workspaceChecks[workspace.id] { await pending.value; return }
        guard canResolve(workspace.id) else { return }
        checkingWorkspaces.insert(workspace.id)
        let task = Task {
            defer { workspaceChecks[workspace.id] = nil; checkingWorkspaces.remove(workspace.id) }
            await readWorkspace(workspace)
        }
        workspaceChecks[workspace.id] = task
        await task.value
    }

    func enqueue(workspaceId: String) {
        requested.insert(workspaceId)
        persist()
        retryAfter[workspaceId] = nil
        if work(for: workspaceId)?.updateOperation?.force == true, needsObservation(workspaceId) {
            observe(workspaceId)
            return
        }
        start(workspaceId, operation: .update(automatic: false))
    }

    /// Called by foreground reconciliation, not by rendering a row. Stopped workspaces
    /// stay untouched; retries are throttled independently of navigation.
    func reconcile(_ workspaces: [Workspace]) {
        for id in Set(workspaces.map(\.id)).union(requested) where needsObservation(id) && due(id) {
            observe(id)
        }
        for id in requested where due(id) && updateRequests[id] == nil && !needsObservation(id) {
            start(id, operation: .update(automatic: false))
        }
        guard automaticUpdates else {
            for (key, state) in coordinator.states where key.agentType == nil && !requested.contains(key.workspaceId) {
                state.updateWaiting = false
            }
            return
        }
        for workspace in workspaces where !workspace.runtime.isLocal {
            let id = workspace.id, key = DaemonWorkKey(workspaceId: workspace.id)
            guard !requested.contains(id), !active.contains(id), due(id),
                  !needsObservation(id),
                  updateRequests[id] == nil, !checkingWorkspaces.contains(id),
                  let state = coordinator.states[key], !state.workspaceUnavailable, !state.running,
                  stores?.preparation.active.contains(where: { $0.workspaceId == id }) != true,
                  !coordinator.hasActiveWork(workspaceId: id) else { continue }
            if state.reachable == false, state.installedVersion == nil,
               !workspace.isCloud || state.workspaceStatus?.power == .running {
                // A failed health check only schedules a preflight. The shared preparation
                // path must confirm the binary is absent before it may install anything.
                start(id, operation: .setup)
            } else if state.reachable == true, state.updateAvailable,
                      (state.health?.serviceUpdateVersion ?? 0) >= 1 {
                start(id, operation: .update(automatic: true))
            }
        }
    }

    func forget(workspaceId: String) {
        requested.remove(workspaceId)
        checkRequests[workspaceId] = nil
        updateRequests[workspaceId] = nil
        retryAfter[workspaceId] = nil
        persist()
    }

    private func due(_ id: String) -> Bool { retryAfter[id].map { now() >= $0 } ?? true }

    private func needsObservation(_ id: String) -> Bool {
        guard let state = work(for: id), let operation = state.updateOperation else { return false }
        return operation.isActive || (operation.status == "complete"
            && !DaemonRelease.satisfies(state.installedVersion, target: operation.version))
    }

    /// Polling an accepted controller request must not re-enter installation or
    /// replace a ready agent page with preparation UI every few seconds.
    private func observe(_ id: String) {
        guard canResolve(id), observations[id] == nil, !active.contains(id) else { return }
        let key = DaemonWorkKey(workspaceId: id)
        let revision = coordinator.probeRevision(key)
        retryAfter[id] = now().addingTimeInterval(3)
        observations[id] = Task {
            defer { observations[id] = nil; persist() }
            do {
                try await observeUpdate(id)
                guard let state = work(for: id) else { return }
                if state.updateOperation?.status == "failed" {
                    requested.remove(id)
                    retryAfter[id] = now().addingTimeInterval(300)
                } else if state.reachable == true, !state.updateAvailable {
                    requested.remove(id)
                    state.updateWaiting = false
                    retryAfter[id] = now().addingTimeInterval(60)
                } else if state.updateOperation?.status == "waiting", state.updateOperation?.force != true {
                    retryAfter[id] = now().addingTimeInterval(15)
                }
            } catch {
                // The accepted receipt remains valid through the service restart.
                coordinator.recordUpdateCheckFailure(error, for: key, revision: revision)
            }
        }
    }

    private func start(_ id: String, operation: Operation) {
        guard canResolve(id), active.count < 3 else { return }
        if case .update = operation,
           let state = coordinator.states[.init(workspaceId: id)],
           state.workspaceUnavailable || state.reachable == false { return }
        guard active.insert(id).inserted else { return }
        let task = Task {
            let state = coordinator.states[.init(workspaceId: id)]
            let targetVersion = state?.latestVersion
            defer {
                // An Update tap made during setup still needs its own version/idle check.
                if case .setup = operation, requested.contains(id) { retryAfter[id] = nil }
                active.remove(id)
                operations[id] = nil
                if case .update(automatic: true) = operation, requested.contains(id) {
                    retryAfter[id] = nil
                }
                persist()
                if case .update = operation {
                    for pending in requested where due(pending) {
                        if needsObservation(pending), work(for: pending)?.updateOperation?.force == true { observe(pending) }
                        else { start(pending, operation: .update(automatic: false)) }
                    }
                }
            }
            switch operation {
            case .setup, .update(automatic: true):
                guard automaticUpdates else { return }
            case .update(automatic: false): break
            }
            do {
                switch operation {
                case .setup: try await prepare(id)
                case .update(let automatic):
                    // Only pass a version verified in this app session. A delayed/offline
                    // request rechecks the release when it eventually becomes runnable.
                    let verifiedTarget = releaseCheckError == nil && releaseCheckedAt.map {
                        let age = now().timeIntervalSince($0)
                        return age >= 0 && age < 300
                    } == true ? latestVersion : nil
                    try await update(id, automatic, verifiedTarget)
                    if requested.contains(id), state?.latestVersion != targetVersion,
                       state?.updateAvailable == true {
                        // A newer release discovered during this install still belongs to
                        // the manual request, even if automatic updates were switched off.
                        state?.updateWaiting = true
                        retryAfter[id] = nil
                        return
                    }
                    requested.remove(id)
                }
                state?.updateWaiting = false
                retryAfter[id] = now().addingTimeInterval(60)
            } catch let pending as DaemonUpdatePending {
                state?.updateOperation = pending.operation
                state?.updateWaiting = pending.operation.status == "waiting"
                // The computer has accepted this update and continues without the app.
                // Keep the local intent until its running version is verified as well.
                retryAfter[id] = now().addingTimeInterval(pending.operation.status == "waiting"
                    && pending.operation.observationError == nil ? 15 : 3)
            } catch DaemonUpdateError.busy {
                state?.updateWaiting = true
                // Approval/input waits count as active work too. A later foreground
                // tick retries after the service reports that all work has finished.
                retryAfter[id] = now().addingTimeInterval(15)
            } catch {
                if case .update(automatic: false) = operation { requested.remove(id) }
                retryAfter[id] = now().addingTimeInterval(300)
                coordinator.recordOperationFailure(error, for: .init(workspaceId: id),
                    activity: { if case .setup = operation { return .installingDaemon }; return .updatingDaemon }())
                APILog.note("Service setup/update: \(error.localizedDescription.oneLine())")
            }
        }
        operations[id] = task
    }

    private func persist() { defaults.set(requested.sorted(), forKey: Self.requestsKey) }
}
