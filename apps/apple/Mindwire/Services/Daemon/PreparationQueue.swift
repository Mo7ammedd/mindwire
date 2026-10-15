import Foundation
import Observation
import OblienKit

/// An outbox of requested preparations, not a cache of installed/running state. The service owns
/// those facts. Pending requests survive navigation and relaunch; all installers still share the
/// workspace/harness lock in DaemonWorkCoordinator and the native /setup job.
@MainActor @Observable
final class PreparationQueue {
    private(set) var active: Set<DaemonWorkKey> = []
    private(set) var pendingIDs: Set<String>
    private(set) var pendingWorkspaceIDs: Set<String>
    @ObservationIgnored private weak var stores: Stores?
    @ObservationIgnored private let prepare: @MainActor (Agent) async throws -> Void
    @ObservationIgnored private let prepareWorkspace: @MainActor (String) async throws -> Void
    @ObservationIgnored private let canResolve: @MainActor (String) -> Bool
    @ObservationIgnored private let waitBeforeRetry: @MainActor (Duration) async throws -> Void
    private static let storageKey = "mindwire:pending-agent-preparations:v2"
    private static let workspaceStorageKey = "mindwire:pending-workspace-preparations:v2"

    init(stores: Stores, canResolve: (@MainActor (String) -> Bool)? = nil,
         prepareWorkspace: (@MainActor (String) async throws -> Void)? = nil,
         waitBeforeRetry: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         prepare: (@MainActor (Agent) async throws -> Void)? = nil) {
        self.stores = stores
        pendingIDs = Set(stores.defaults.stringArray(forKey: Self.storageKey) ?? [])
        pendingWorkspaceIDs = Set(stores.defaults.stringArray(forKey: Self.workspaceStorageKey) ?? [])
        // The old queue retained completed failures as pending. Those ambiguous requests must
        // not restart installs on app open; live remote jobs are still discovered by status reads.
        stores.defaults.removeObject(forKey: "mindwire:pending-agent-preparations:v1")
        stores.defaults.removeObject(forKey: "mindwire:pending-workspace-preparations:v1")
        self.canResolve = canResolve ?? { WorkspaceRepository.shared.get($0) != nil }
        self.waitBeforeRetry = waitBeforeRetry
        self.prepareWorkspace = prepareWorkspace ?? { [weak stores] workspaceId in
            guard let stores else { throw CancellationError() }
            if let workspace = WorkspaceRepository.shared.get(workspaceId), workspace.isCloud {
                let api = OblienCloud.client.workspaces
                let value = try await api.get(workspaceId)
                if let preparation = value.provisioning, preparation.state != "ready" {
                    // Only explicitly queued creation/setup requests enter this path.
                    // A suspended or stopped existing workspace is never auto-started here.
                    _ = try await api.waitUntilReady(workspaceId, options: .init(timeout: 1800, onProgress: { value in
                        await MainActor.run {
                            DaemonWorkCoordinator.shared.recordWorkspaceStatus(.init(cloud: value), for: .init(workspaceId: workspaceId))
                        }
                    }))
                    await WorkspaceRepository.shared.refresh()
                }
            }
            try await stores.workspaceData.prepareDaemon(workspaceId: workspaceId)
        }
        self.prepare = prepare ?? { [weak stores] agent in
            guard let stores else { throw CancellationError() }
            let session = DaemonManager.shared.session(for: agent.id, stores: stores)
            await session.load(force: true) // this queue contains explicit creation/setup/retry requests
            if let error = session.loadError { throw BackendError.message(error) }
            if let workspaceId = agent.workspaceId, let workspace = WorkspaceRepository.shared.get(workspaceId) {
                // Confirm a just-installed CLI at the source before clearing the setup row.
                // This runs once per explicit setup, never as an idle/background poll.
                await stores.workspaceData.refresh(workspace)
            }
        }
    }

    func enqueue(_ agent: Agent) {
        guard agent.workspaceId != nil else { return }
        pendingIDs.insert(agent.id)
        persist()
        start(agent)
    }

    func enqueue(workspaceId: String) {
        pendingWorkspaceIDs.insert(workspaceId)
        persist()
        start(workspaceId: workspaceId)
    }

    /// Called once after inventory reconciliation on launch/foreground, not on every list poll.
    /// Only requested preparations are resumed; reading inventory never installs software.
    func resume() {
        guard let stores else { return }
        for id in pendingWorkspaceIDs { start(workspaceId: id) }
        for id in pendingIDs {
            guard let agent = stores.agents.get(id) else { continue }
            start(agent)
        }
    }

    func forget(agentId: String) {
        pendingIDs.remove(agentId)
        persist()
    }

    func forget(workspaceId: String) {
        guard let stores else { return }
        pendingWorkspaceIDs.remove(workspaceId)
        pendingIDs = pendingIDs.filter {
            guard let agent = stores.agents.get($0) else { return false }
            return agent.workspaceId != workspaceId
        }
        persist()
    }

    private func start(_ agent: Agent) {
        guard let workspaceId = agent.workspaceId, canResolve(workspaceId) else { return }
        let key = DaemonWorkKey(workspaceId: workspaceId, agentType: agent.agentType.rawValue)
        start(key) {
            try await self.prepare(agent)
        }
    }

    private func start(workspaceId: String) {
        guard canResolve(workspaceId) else { return }
        start(.init(workspaceId: workspaceId)) {
            // A newly created cloud workspace may still be starting. Every retry probes the
            // real service before installing, so a completed launch is never installed twice.
            for attempt in 0..<5 {
                guard self.pendingWorkspaceIDs.contains(workspaceId), self.canResolve(workspaceId) else {
                    throw CancellationError()
                }
                do {
                    try await self.prepareWorkspace(workspaceId)
                    break
                } catch {
                    guard attempt < 4, Self.isTemporaryConnectionFailure(error) else { throw error }
                    try await self.waitBeforeRetry(.seconds(2 << attempt))
                }
            }
        }
    }

    static func isTemporaryConnectionFailure(_ error: Error) -> Bool {
        let unavailable = [502, 503, 504]
        if let error = error as? DaemonHTTPError { return unavailable.contains(error.status) }
        if let error = error as? OblienError {
            return error.kind == .transport || unavailable.contains(error.status ?? 0)
        }
        if let error = error as? URLError {
            return [.cannotConnectToHost, .networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code)
        }
        return false
    }

    private func start(_ key: DaemonWorkKey, operation: @escaping @MainActor () async throws -> Void) {
        guard active.insert(key).inserted else { return }
        // This task belongs to the request queue, not the sheet's lifetime.
        Task {
            defer {
                finish(key)
                persist()
                active.remove(key)
            }
            do {
                try await operation()
            } catch {
                // Keep the workspace/profile and its visible error, but require an explicit
                // retry after failure. Foreground reconciliation only resumes unfinished work.
                APILog.note("Workspace preparation: \(error.localizedDescription.oneLine())")
            }
        }
    }

    private func finish(_ key: DaemonWorkKey) {
        guard let agentType = key.agentType else {
            pendingWorkspaceIDs.remove(key.workspaceId)
            return
        }
        guard let stores else { return }
        pendingIDs = pendingIDs.filter { id in
            guard let agent = stores.agents.get(id) else { return false }
            return agent.workspaceId != key.workspaceId || agent.agentType.rawValue != agentType
        }
    }

    private func persist() {
        stores?.defaults.set(pendingIDs.sorted(), forKey: Self.storageKey)
        stores?.defaults.set(pendingWorkspaceIDs.sorted(), forKey: Self.workspaceStorageKey)
    }
}
