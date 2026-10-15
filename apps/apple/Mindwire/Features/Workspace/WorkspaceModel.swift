import Foundation

/// Loads the workspace control surface for one agent: health + capabilities, then
/// resources / ports / files concurrently. The view branches only on `caps` + `health`.
@Observable
@MainActor
final class WorkspaceModel {
    private let backend: Backend
    private let now: () -> Date
    private let onChange: () -> Void
    private let coordinator: DaemonWorkCoordinator
    private let daemonKey: DaemonWorkKey
    private let wait: () async throws -> Void
    private let verifyService: () async -> Bool
    private let startService: () async -> Void
    private var freshness = RefreshState()
    private var loadTask: Task<Void, Never>?
    private var powerTask: Task<Void, Never>?
    private var resourceTask: Task<Bool, Never>?
    private var resourcePatch: WorkspaceResourcePatch?
    private(set) var updatingResources = false

    private(set) var loading = true
    private(set) var error: String?

    private(set) var health: BackendHealth?
    private(set) var caps: WorkspaceCapabilities = .none
    var status: WorkspaceStatus? { coordinator.states[daemonKey]?.workspaceStatus }
    var powerAction: PowerAction? { coordinator.states[daemonKey]?.powerAction }
    private(set) var resources: WorkspaceResources?
    private(set) var ports: [ExposedPort] = []
    private(set) var management: WorkspaceManagementModel?

    init(backend: Backend, now: @escaping () -> Date = Date.init, onChange: @escaping () -> Void = {},
         workspaceId: String? = nil, coordinator: DaemonWorkCoordinator? = nil,
         wait: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
         verifyService: @escaping () async -> Bool = { true }, startService: @escaping () async -> Void = {}) {
        self.backend = backend
        self.now = now
        self.onChange = onChange
        self.coordinator = coordinator ?? .shared
        self.daemonKey = .init(workspaceId: workspaceId ?? UUID().uuidString)
        self.wait = wait
        self.verifyService = verifyService
        self.startService = startService
        if let service = backend.workspace.management {
            self.management = WorkspaceManagementModel(service: service) { [weak self] in
                guard let self else { return }
                self.freshness.invalidate()
                self.coordinator.invalidateWorkspaceStatus(self.daemonKey)
                self.onChange()
                await self.load(force: true)
            }
        }
    }

    var workspace: WorkspaceService { backend.workspace }
    var runtime: AgentRuntime { backend.runtime }

    func dispose() async {
        management?.dispose()
        freshness.invalidate()
        loadTask?.cancel()
        powerTask?.cancel()
        resourceTask?.cancel()
        await backend.dispose()
    }

    /// True when the backend is healthy and at least one capability is enabled.
    var available: Bool {
        guard let health, health.ok else { return false }
        return caps != .none
    }

    func load(force: Bool = false) async {
        if let loadTask {
            let revision = freshness.revision
            await loadTask.value
            if force && (revision != freshness.revision || !freshness.isFresh(at: now())) { await load(force: true) }
            return
        }
        let transitioning = status?.power.isTransitioning == true || powerAction != nil
        guard force || !freshness.isFresh(at: now(), maxAge: transitioning ? 3 : 60) else { return }
        let checkRevision = freshness.revision
        let task = Task {
            defer { loadTask = nil }
            await read(checkRevision: checkRevision, force: force)
        }
        loadTask = task
        await task.value
    }

    private func read(checkRevision: Int, force: Bool) async {
        loading = health == nil
        defer { loading = false }

        let health = await backend.healthCheck()
        let caps = backend.workspace.capabilities
        guard !Task.isCancelled, freshness.revision == checkRevision else { return }

        guard health.ok, caps != .none else {
            self.health = health
            self.caps = caps
            freshness.finish(success: false, at: now(), revision: checkRevision)
            onChange()
            return
        }
        self.health = health
        self.caps = caps

        // Only the lightweight management calls gate the UI. Files are NOT fetched here — they'd
        // force a runtime handshake (slow) and aren't shown on this page anyway; the Files sheet
        // self-loads on demand.
        do {
            // Publish power independently: a ports/resources failure must not hide the Start action.
            _ = try await readStatus(force: force)
            async let resourcesResult = caps.resources ? backend.workspace.getResources() : nil
            async let portsResult = caps.ports ? backend.workspace.listPorts() : []
            let values = try await (resourcesResult, portsResult)
            guard !Task.isCancelled, freshness.revision == checkRevision else { return }
            self.health = health
            self.caps = caps
            resources = values.0
            ports = values.1
            error = nil
            freshness.finish(success: true, at: now(), revision: checkRevision)
        } catch {
            guard !Task.isCancelled, freshness.revision == checkRevision else { return }
            self.error = error.localizedDescription
            freshness.finish(success: false, at: now(), revision: checkRevision)
            onChange()
        }
    }

    private func readStatus(force: Bool = false) async throws -> WorkspaceStatus {
        try await coordinator.readWorkspaceStatus(for: daemonKey, force: force, at: now()) {
            try await self.backend.workspace.status()
        }
    }

    /// One workspace-owned operation survives navigation and verifies both the VM and service.
    /// Acknowledging Start is not proof that either has finished starting.
    func power(_ action: PowerAction) async {
        if let powerTask { await powerTask.value; return }
        if management?.isBusy == true && (action != .stop || management?.actionTitle != nil || management?.externalOperation == true) {
            error = "Wait for the current workspace operation to finish."
            return
        }
        management?.externalOperation = true
        let task = Task {
            defer { powerTask = nil; management?.externalOperation = false; management?.invalidateAll() }
            freshness.invalidate()
            coordinator.beginPowerAction(action, for: daemonKey)
            onChange()
            error = nil
            var failure: String?
            defer { coordinator.finishPowerAction(for: daemonKey, error: failure) }
            do {
                try await backend.workspace.power(action)
                try Task.checkCancellation()
                // Drop any management/health request that began before the command was accepted.
                coordinator.invalidateWorkspaceStatus(daemonKey)
                onChange()
                let expected: WorkspacePower = action == .stop ? .stopped : .running
                var serviceStartAttempts = 0
                for attempt in 0..<30 {
                    try Task.checkCancellation()
                    do {
                        let latest = try await readStatus(force: true)
                        if latest.power == expected {
                            if action == .stop { return }
                            if await verifyService() { return }
                            if serviceStartAttempts < 3 {
                                serviceStartAttempts += 1
                                await startService()
                                if await verifyService() { return }
                            }
                        }
                    } catch {
                        guard attempt < 29, PreparationQueue.isTemporaryConnectionFailure(error) else { throw error }
                    }
                    if attempt < 29 { try await wait() }
                }
                if status?.power != expected {
                    failure = t("workspace.power.timeout")
                }
                // If the VM is running, preserve the actual service failure from its probe.
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
                self.error = failure
                coordinator.invalidateWorkspaceStatus(daemonKey)
                _ = try? await readStatus(force: true)
            }
        }
        powerTask = task
        await task.value
        if let management {
            await management.refresh(.settings, force: true)
            if management.installation.value?.isPending == true { await management.refresh(.desktop, force: true) }
        }
    }

    @discardableResult
    func updateResources(_ patch: WorkspaceResourcePatch) async -> Bool {
        if let resourceTask {
            guard resourcePatch == patch else { return false }
            return await resourceTask.value
        }
        guard powerAction == nil, management?.isBusy != true else {
            error = "Wait for the current workspace operation to finish."
            return false
        }
        updatingResources = true; resourcePatch = patch; management?.externalOperation = true
        let task = Task { @MainActor in
            defer { resourceTask = nil; resourcePatch = nil; updatingResources = false; management?.externalOperation = false }
            freshness.invalidate(); error = nil; onChange()
            do {
                resources = try await backend.workspace.updateResources(patch)
                coordinator.invalidateWorkspaceStatus(daemonKey)
                management?.invalidateAll()
                await load(force: true)
                return true
            } catch {
                self.error = WorkspaceControlError.describe(error)
                management?.invalidateAll()
                return false
            }
        }
        resourceTask = task
        return await task.value
    }

    func exposePort(_ port: Int) async {
        freshness.invalidate()
        do {
            _ = try await backend.workspace.exposePort(ExposePortInput(port: port))
            ports = (try? await backend.workspace.listPorts()) ?? ports
        } catch {
            self.error = error.localizedDescription
        }
    }

    func unexposePort(_ port: Int) async {
        freshness.invalidate()
        do {
            try await backend.workspace.unexposePort(port)
            ports = (try? await backend.workspace.listPorts()) ?? ports
        } catch {
            self.error = error.localizedDescription
        }
    }
}
