import Foundation
import Observation

/// A section keeps its last good value through refresh and failures. Navigating back to it does
/// not create a new check. Invalidating prevents a pre-mutation response from restoring old data.
@Observable @MainActor
final class WorkspaceControlValue<Value> {
    private(set) var value: Value?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var loaded = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var taskID: UUID?
    @ObservationIgnored private var taskRevision: Int?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func load(force: Bool = false, read: @escaping @MainActor () async throws -> Value) async {
        guard !closed else { return }
        if let task {
            let generation = taskRevision
            await task.value
            if !closed, generation != revision { await load(force: force, read: read) }
            return
        }
        guard force || (checkedAt.map({ now().timeIntervalSince($0) >= 300 }) ?? true) else { return }
        let generation = revision
        let identifier = UUID()
        taskID = identifier; taskRevision = generation; loading = true
        let pending = Task { @MainActor in
            defer { if taskID == identifier { loading = false; task = nil; taskID = nil; taskRevision = nil } }
            do {
                let result = try await read()
                guard !Task.isCancelled, generation == revision else { return }
                value = result; error = nil; loaded = true; checkedAt = now()
            } catch {
                guard !Task.isCancelled, generation == revision else { return }
                self.error = WorkspaceControlError.describe(error)
            }
        }
        task = pending
        await pending.value
    }
    func invalidate() { revision &+= 1; checkedAt = nil }
    func cancel() { closed = true; invalidate(); task?.cancel(); task = nil; taskID = nil; taskRevision = nil; loading = false }
    func replace(_ value: Value) { invalidate(); self.value = value; loaded = true; checkedAt = now(); error = nil }
}

/// Owned by the repository's WorkspaceModel, not a tab or a sheet. Mutations are serialized and
/// installation/copy progress follows server-owned operations after navigation or an app restart.
@Observable @MainActor
final class WorkspaceManagementModel {
    let service: WorkspaceManagementService
    let info = WorkspaceControlValue<ManagedWorkspace>()
    let workspaceChoices = WorkspaceControlValue<[ManagedWorkspace]>()
    let disks = WorkspaceControlValue<WorkspaceDiskList>()
    let allDisks = WorkspaceControlValue<[WorkspaceManagedDisk]>()
    let software = WorkspaceControlValue<[WorkspaceSoftware]>()
    let installation = WorkspaceControlValue<WorkspaceDesktopInstallation>()
    let desktop = WorkspaceControlValue<WorkspaceDesktopAccess>()
    let workloads = WorkspaceControlValue<[WorkspaceManagedWorkload]>()
    let workloadTargets = WorkspaceControlValue<[WorkspaceExecutionTarget]>()
    let workloadActivity: WorkspaceWorkloadActivity
    let network = WorkspaceControlValue<WorkspaceNetwork>()
    let outboundIPs = WorkspaceControlValue<[WorkspaceOutboundIP]>()
    let ports = WorkspaceControlValue<[ExposedPort]>()
    let domain = WorkspaceControlValue<WorkspaceDomain?>()
    let ssh = WorkspaceControlValue<WorkspaceSSHAccess>()
    let apiAccess = WorkspaceControlValue<WorkspaceRuntimeAccess>()
    let lifecycle = WorkspaceControlValue<WorkspaceLifecycle>()
    let archives = WorkspaceControlValue<[WorkspaceArchive]>()
    let images = WorkspaceControlValue<[WorkspaceImageOption]>()
    private(set) var operations: [String: WorkspaceDiskOperation] = [:]
    private(set) var operationError: String?
    private(set) var actionTitle: String?
    var actionError: String?
    var externalOperation = false
    @ObservationIgnored private var activeCommand: WorkspaceManagementCommand?
    @ObservationIgnored private var mutation: Task<WorkspaceManagementResult?, Never>?
    @ObservationIgnored private var diskWatcher: Task<Void, Never>?
    @ObservationIgnored private var desktopWatcher: Task<Void, Never>?
    @ObservationIgnored private var diskKeys: [WorkspaceDiskAction: String] = [:]
    @ObservationIgnored private var disposed = false
    @ObservationIgnored private let wait: @MainActor () async throws -> Void
    @ObservationIgnored private let onMutation: @MainActor () async -> Void

    init(service: WorkspaceManagementService,
         wait: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
         onMutation: @escaping @MainActor () async -> Void = {}) {
        self.service = service; self.wait = wait; self.onMutation = onMutation
        workloadActivity = WorkspaceWorkloadActivity(service: service)
    }
    var features: Set<WorkspaceManagementFeature> { service.features }
    var isBusy: Bool { externalOperation || actionTitle != nil || installation.value?.isPending == true || operations.values.contains(where: \.isPending) }
    var storageBlockedReason: String? {
        if operations.values.contains(where: \.isPending) { return "A disk operation is in progress." }
        guard let workspace = info.value else { return "Refresh the workspace status before changing storage." }
        if workspace.hasSavedExecution { return "Resume and stop the workspace, or discard saved memory, before changing disks." }
        return workspace.isColdStopped ? nil : "Stop the workspace before attaching, detaching, or copying its writable storage."
    }

    func refresh(_ feature: WorkspaceManagementFeature, force: Bool = false) async {
        guard !disposed, features.contains(feature) else { return }
        switch feature {
        case .disks:
            async let a: Void = info.load(force: force) { try await self.service.workspace() }
            async let b: Void = disks.load(force: force) { try await self.service.disks() }
            _ = await (a, b)
            let ids = Set((disks.value?.disks.compactMap(\.operationId) ?? []) + [disks.value?.operationId].compactMap { $0 })
            for id in ids where operations[id] == nil {
                do { operations[id] = try await service.diskOperation(id) }
                catch { operationError = WorkspaceControlError.describe(error) }
            }
            watchDisks()
        case .desktop:
            async let a: Void = info.load(force: force) { try await self.service.workspace() }
            async let b: Void = installation.load(force: force) { try await self.service.desktopInstallation() }
            _ = await (a, b)
            if info.value?.isRunning == true, installation.value?.isPending != true {
                await desktop.load(force: force) { try await self.service.desktopStatus() }
            }
            watchDesktop()
        case .workloads: await workloads.load(force: force) { try await self.service.workloads() }
        case .network: await network.load(force: force) { try await self.service.network() }
        case .publicAccess:
            async let a: Void = network.load(force: force) { try await self.service.network() }
            async let b: Void = ports.load(force: force) { try await self.service.publicPorts() }
            async let c: Void = domain.load(force: force) { try await self.service.domain() }
            async let d: Void = lifecycle.load(force: force) { try await self.service.lifecycle() }
            _ = await (a, b, c, d)
        case .ssh: await ssh.load(force: force) { try await self.service.ssh() }
        case .apiAccess: await apiAccess.load(force: force) { try await self.service.runtimeAccess() }
        case .settings:
            async let a: Void = info.load(force: force) { try await self.service.workspace() }
            async let b: Void = lifecycle.load(force: force) { try await self.service.lifecycle() }
            _ = await (a, b)
        case .archives: await archives.load(force: force) { try await self.service.archives() }
        case .logs: break
        }
    }

    func loadAvailableDisks(force: Bool = false) async {
        await allDisks.load(force: force) { try await self.service.allDisks() }
        for id in Set(allDisks.value?.compactMap(\.operationId) ?? []) where operations[id] == nil {
            do { operations[id] = try await service.diskOperation(id) }
            catch { operationError = WorkspaceControlError.describe(error) }
        }
        watchDisks()
    }
    func loadWorkspaceChoices(force: Bool = false) async {
        await workspaceChoices.load(force: force) { try await self.service.workspaces() }
    }
    func loadSoftware(force: Bool = false) async { await software.load(force: force) { try await self.service.software() } }
    func loadImages(force: Bool = false) async { await images.load(force: force) { try await self.service.images() } }
    func loadOutboundIPs(force: Bool = false) async { await outboundIPs.load(force: force) { try await self.service.outboundIPs() } }
    func loadWorkloadTargets(force: Bool = false) async { await workloadTargets.load(force: force) { try await self.service.workloadTargets() } }

    /// Repeated taps join the in-flight request. A new screen observes the same action and cannot
    /// send a conflicting mutation while disk or desktop preparation owns the workspace.
    @discardableResult
    func execute(_ command: WorkspaceManagementCommand, title: String,
                 refresh features: Set<WorkspaceManagementFeature> = []) async -> WorkspaceManagementResult? {
        if let mutation {
            guard activeCommand == command else { actionError = "Wait for the current workspace operation to finish."; return nil }
            return await mutation.value
        }
        guard !disposed else { return nil }
        guard !isBusy else { actionError = "Wait for the current workspace operation to finish."; return nil }
        activeCommand = command; actionTitle = title; actionError = nil
        let task = Task { @MainActor () -> WorkspaceManagementResult? in
            defer { actionTitle = nil; mutation = nil; activeCommand = nil }
            do {
                let result = try await service.perform(command)
                guard !Task.isCancelled, !disposed else { return nil }
                invalidate(features)
                switch result {
                case .disk(let response):
                    if let operation = response.operation { operations[operation.id] = operation }
                    watchDisks()
                case .desktop(let response): installation.replace(response); watchDesktop()
                default: break
                }
                for feature in features { await refresh(feature, force: true) }
                // Access-token reads/DNS checks do not invalidate workspace health.
                if !features.isEmpty { await onMutation() }
                return result
            } catch is CancellationError { return nil }
            catch {
                guard !disposed else { return nil }
                let message = WorkspaceControlError.describe(error)
                invalidate(features)
                for feature in features { await refresh(feature, force: true) }
                if !features.isEmpty { await onMutation() }
                actionError = message
                return nil
            }
        }
        mutation = task
        return await task.value
    }

    @discardableResult
    func diskAction(_ action: WorkspaceDiskAction) async -> Bool {
        let key = diskKeys[action] ?? UUID().uuidString
        diskKeys[action] = key
        let result = await execute(.disk(action, idempotencyKey: key), title: action.kind.progressTitle, refresh: [.disks])
        if result != nil {
            diskKeys[action] = nil
            if allDisks.loaded { await loadAvailableDisks(force: true) }
        }
        return result != nil
    }

    private func invalidate(_ features: Set<WorkspaceManagementFeature>) {
        for feature in features {
            switch feature {
            case .disks: disks.invalidate(); allDisks.invalidate(); info.invalidate(); workspaceChoices.invalidate()
            case .desktop: installation.invalidate(); desktop.invalidate(); info.invalidate()
            case .workloads: workloads.invalidate(); workloadTargets.invalidate()
            case .network: network.invalidate()
            case .publicAccess: ports.invalidate(); domain.invalidate(); network.invalidate(); lifecycle.invalidate()
            case .ssh: ssh.invalidate()
            case .apiAccess: apiAccess.invalidate(); desktop.invalidate()
            case .settings: info.invalidate(); lifecycle.invalidate()
            case .archives: archives.invalidate()
            case .logs: break
            }
        }
    }

    private func watchDisks() {
        guard diskWatcher == nil, operations.values.contains(where: \.isPending), !disposed else { return }
        diskWatcher = Task { @MainActor in
            defer { diskWatcher = nil }
            var failures = 0
            while !Task.isCancelled, !disposed, operations.values.contains(where: \.isPending) {
                do {
                    try await wait()
                    for id in operations.values.filter(\.isPending).map(\.id) {
                        let operation = try await service.diskOperation(id)
                        guard !disposed, !Task.isCancelled else { return }
                        operations[id] = operation
                    }
                    operationError = nil; failures = 0
                } catch is CancellationError { return }
                catch {
                    operationError = WorkspaceControlError.describe(error); failures += 1
                    if failures >= 3 { return } // The operation is still remote; Refresh resumes observation.
                }
            }
            guard !disposed, !Task.isCancelled else { return }
            disks.invalidate(); allDisks.invalidate(); info.invalidate()
            await refresh(.disks, force: true)
            if allDisks.loaded { await loadAvailableDisks(force: true) }
            await onMutation()
        }
    }

    private func watchDesktop() {
        guard desktopWatcher == nil, installation.value?.isPending == true, !disposed else { return }
        desktopWatcher = Task { @MainActor in
            defer { desktopWatcher = nil }
            var failures = 0
            while !Task.isCancelled, !disposed, installation.value?.isPending == true {
                do {
                    try await wait()
                    let value = try await service.desktopInstallation()
                    guard !disposed, !Task.isCancelled else { return }
                    installation.replace(value); operationError = nil; failures = 0
                } catch is CancellationError { return }
                catch {
                    operationError = WorkspaceControlError.describe(error); failures += 1
                    if failures >= 3 { return }
                }
            }
            guard !disposed, !Task.isCancelled else { return }
            info.invalidate(); desktop.invalidate()
            await refresh(.desktop, force: true)
            await onMutation()
        }
    }

    func invalidateAll() { invalidate(Set(WorkspaceManagementFeature.allCases)) }

    func dispose() {
        disposed = true; mutation?.cancel(); diskWatcher?.cancel(); desktopWatcher?.cancel()
        info.cancel(); disks.cancel(); allDisks.cancel(); software.cancel(); installation.cancel(); desktop.cancel()
        workloads.cancel(); network.cancel(); outboundIPs.cancel(); ports.cancel(); domain.cancel(); ssh.cancel()
        workloadTargets.cancel(); workloadActivity.dispose()
        apiAccess.cancel(); lifecycle.cancel(); archives.cancel(); images.cancel(); workspaceChoices.cancel()
    }
}

extension WorkspaceDiskAction.Kind {
    var progressTitle: String {
        switch self {
        case .create: return "Creating disk…"
        case .attach, .attachSoftware: return "Attaching disk…"
        case .detach: return "Detaching disk…"
        case .move: return "Moving disk…"
        case .clone: return "Copying disk…"
        case .save: return "Saving disk…"
        case .fork: return "Creating root…"
        case .resize: return "Growing disk…"
        case .retain: return "Retaining root…"
        case .delete: return "Deleting disk…"
        case .discardSavedExecution: return "Discarding saved memory…"
        case .retry: return "Retrying operation…"
        }
    }
}

@Observable @MainActor
final class WorkspaceLogsModel {
    private(set) var entries: [WorkspaceLogEntry] = []
    private(set) var following = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    let service: WorkspaceManagementService
    let source: WorkspaceLogSource
    init(service: WorkspaceManagementService, source: WorkspaceLogSource) { self.service = service; self.source = source }

    func start() {
        guard task == nil else { return }
        following = true; error = nil
        let current = UUID(); generation = current
        task = Task { @MainActor in
            defer { if current == generation { following = false; task = nil } }
            do {
                for try await event in service.logStream(source) {
                    try Task.checkCancellation()
                    guard current == generation else { return }
                    if event.cleared { entries = [] }
                    entries = Self.bounded(entries + event.entries)
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, current == generation else { return }
                self.error = WorkspaceControlError.describe(error)
                if entries.isEmpty {
                    let fallback = (try? await service.logs(source)) ?? []
                    guard !Task.isCancelled, current == generation else { return }
                    entries = Self.bounded(fallback)
                }
            }
        }
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; following = false }
    func clear() { entries = [] }
    static func bounded(_ values: [WorkspaceLogEntry]) -> [WorkspaceLogEntry] {
        var bytes = 0
        let reversed = values.suffix(2000).reversed().prefix { entry in
            bytes += entry.line.utf8.count + 128
            return bytes <= 1_048_576
        }
        return Array(reversed.reversed())
    }
}
