import Foundation
import Observation
import UIKit

/// Owns transfers outside sheet lifetimes. Only intent/progress is cached here;
/// checkpoints, path locks, conflict decisions and commit recovery live on the daemons.
@MainActor @Observable
final class ProjectSyncCoordinator {
    private(set) var transfers: [String: ProjectTransfer]
    private let stores: Stores
    @ObservationIgnored private let makeRemote: (String) async throws -> ProjectSyncRemote
    @ObservationIgnored private let reconcile: (String) async throws -> Void
    @ObservationIgnored private let retryDelay: (Int) async throws -> Void
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    private static let key = "mindwire:project-transfers:v1"

    init(stores: Stores, makeRemote: ((String) async throws -> ProjectSyncRemote)? = nil,
         reconcile: ((String) async throws -> Void)? = nil,
         retryDelay: @escaping (Int) async throws -> Void = { attempt in
             try await Task.sleep(for: .seconds(1 << attempt))
         }) {
        self.stores = stores
        self.makeRemote = makeRemote ?? { ProjectSyncClient(http: try await stores.workspaceData.projectSyncHTTP(workspaceId: $0)) }
        self.reconcile = reconcile ?? { try await stores.workspaceData.reconcileProjectSync(workspaceId: $0) }
        self.retryDelay = retryDelay
        transfers = stores.defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: ProjectTransfer].self, from: $0) } ?? [:]
    }

    func transfer(for project: Project) -> ProjectTransfer? {
        transfers.values.filter { value in
            value.status != "dismissed" && (value.sourceProjectId == project.id
                || (project.syncId != nil && value.syncId == project.syncId))
        }.max { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func start(project: Project, targetWorkspaceId: String, path: String?, includeIgnored: [String] = [], selectionToken: String? = nil) throws -> String {
        guard targetWorkspaceId != project.workspaceId else { throw BackendError.message(t("project.transfer.sameWorkspace")) }
        let normalizedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let selection = ProjectSyncSelection.normalized(includeIgnored)
        if let old = transfer(for: project), old.active || ["paused", "recovery_required"].contains(old.status) {
            guard old.targetWorkspaceId == targetWorkspaceId, old.sourceProjectId == project.id,
                  old.destinationPath == normalizedPath, (old.includeIgnored ?? []) == selection,
                  old.selectionToken == selectionToken else { throw BackendError.message(t("project.transfer.alreadyRunning")) }
            if tasks[old.id] == nil { launch(old.id, retry: true) }
            return old.id
        }
        let id = UUID().uuidString.lowercased()
        let value = ProjectTransfer(id: id, sourceProjectId: project.id, sourceWorkspaceId: project.workspaceId,
                                    targetWorkspaceId: targetWorkspaceId, syncId: project.syncId,
                                    destinationPath: normalizedPath, includeIgnored: selection, selectionToken: selectionToken, createdAt: isoNow())
        transfers[id] = value
        persist()
        launch(id, retry: false)
        return id
    }

    func resumePending() {
        for value in transfers.values where value.active || value.status == "paused" {
            if tasks[value.id] == nil { launch(value.id, retry: false) }
        }
    }

    func retry(_ id: String) {
        guard transfers[id]?.status != "succeeded", tasks[id] == nil else { return }
        launch(id, retry: true)
    }

    /// Detaches only this relay. An already accepted daemon transaction finishes
    /// independently; reopening reads its result without requiring the old laptop.
    func pause(_ id: String) { tasks[id]?.cancel() }

    func dismissResult(_ id: String) {
        guard let value = transfers[id], !value.active,
              ["succeeded", "failed", "conflicts"].contains(value.status) else { return }
        update(id) { $0.status = "dismissed" }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(transfers) { stores.defaults.set(data, forKey: Self.key) }
    }
    private func update(_ id: String, _ change: (inout ProjectTransfer) -> Void) {
        guard var value = transfers[id] else { return }
        change(&value); transfers[id] = value; persist()
    }

    private func launch(_ id: String, retry: Bool) {
        guard tasks[id] == nil else { return }
        update(id) { $0.status = "running"; $0.error = nil }
        backgroundTasks[id] = UIApplication.shared.beginBackgroundTask(withName: "Project synchronization") { [weak self] in
            Task { @MainActor in self?.pause(id) }
        }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                tasks[id] = nil
                if let token = backgroundTasks.removeValue(forKey: id), token != .invalid {
                    UIApplication.shared.endBackgroundTask(token)
                }
            }
            do {
                for attempt in 0...3 {
                    do {
                        try await execute(id, retry: retry)
                        break
                    } catch {
                        guard attempt < 3, Self.transient(error), !Task.isCancelled else { throw error }
                        try await retryDelay(attempt)
                    }
                }
            } catch let failure as ProjectSyncFailure {
                update(id) { $0.status = failure.operation.status; $0.operation = failure.operation; $0.error = failure.localizedDescription }
            } catch is CancellationError {
                update(id) { $0.status = "paused"; $0.error = nil }
            } catch {
                let permanent = error is WorkspaceRegistryError || error is ProjectTransferError
                    || ((error as? DaemonHTTPError).map { (400..<500).contains($0.status) && ![408, 429].contains($0.status) } ?? false)
                update(id) { $0.status = permanent ? "failed" : "paused"; $0.error = error.localizedDescription }
            }
        }
    }

    private static func transient(_ error: Error) -> Bool {
        if error is CancellationError || error is ProjectSyncFailure || error is WorkspaceRegistryError || error is ProjectTransferError { return false }
        if let error = error as? DaemonHTTPError { return error.status >= 500 || [408, 429].contains(error.status) }
        if let error = error as? URLError { return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) }
        return false
    }

    private func execute(_ id: String, retry: Bool) async throws {
        guard let initial = transfers[id] else { return }
        let target = try await makeRemote(initial.targetWorkspaceId)
        let targetIdentity = stores.workspaceData.identity(workspaceId: initial.targetWorkspaceId)
        if let previous = initial.targetIdentity, let targetIdentity, previous != targetIdentity {
            throw ProjectTransferError.identityChanged
        }
        update(id) { $0.targetIdentity = targetIdentity }
        var checkpointId = initial.checkpointId
        var ready = initial.didRelay
        if let checkpointId, !ready {
            do { _ = try await target.checkpoint(checkpointId); ready = true }
            catch let error as DaemonHTTPError where error.status == 404 { /* resume missing chunks */ }
        }
        if !ready {
            // A pending transfer created by an older app may contain the whole
            // dependency tree. Review it before sending any more legacy bytes.
            guard initial.includeIgnored != nil else { throw ProjectTransferError.reviewRequired }
            let source = try await makeRemote(initial.sourceWorkspaceId)
            let sourceIdentity = stores.workspaceData.identity(workspaceId: initial.sourceWorkspaceId)
            if let previous = initial.sourceIdentity, let sourceIdentity, previous != sourceIdentity {
                throw ProjectTransferError.identityChanged
            }
            if sourceIdentity != nil, sourceIdentity == targetIdentity {
                throw WorkspaceRegistryError.projectSyncUnavailable
            }
            update(id) { $0.sourceIdentity = sourceIdentity }
            if checkpointId == nil {
                update(id) { $0.phase = "checkpoint" }
                var operation = try await source.export(id: id + "-export", projectId: initial.sourceProjectId, includeIgnored: initial.includeIgnored ?? [], selectionToken: initial.selectionToken)
                if retry, !operation.active, operation.status != "succeeded" { operation = try await source.retry(operation.id) }
                operation = try await wait(id, remote: source, operation: operation)
                guard let result = operation.resultCheckpointId else { throw ProjectTransferError.invalidData }
                checkpointId = result
                update(id) { $0.checkpointId = result }
            }
            guard let checkpointId else { throw ProjectTransferError.invalidData }
            let checkpoint = try await source.checkpoint(checkpointId)
            update(id) { $0.syncId = checkpoint.projectId; $0.phase = "transfer" }
            // This logical ID is acknowledged by the source checkpoint. Cache it
            // immediately so a second workspace copy cannot create a duplicate card.
            if var project = stores.projects.get(initial.sourceProjectId) {
                project.syncId = checkpoint.projectId
                stores.projects.save(project)
            }
            try await relay(id, source: source, target: target, checkpoint: checkpoint)
            update(id) { $0.didRelay = true }
        }
        guard let checkpointId else { throw ProjectTransferError.invalidData }
        update(id) { $0.phase = "apply"; $0.didRelay = true }
        var operation = try await target.importCheckpoint(id: id + "-import", checkpointId: checkpointId, path: initial.destinationPath, includeIgnored: initial.includeIgnored ?? [], selectionToken: initial.selectionToken)
        if retry, !operation.active, operation.status != "succeeded" { operation = try await target.retry(operation.id) }
        operation = try await wait(id, remote: target, operation: operation)
        guard let projectId = operation.resultProjectId else { throw ProjectTransferError.invalidData }
        try await reconcile(initial.targetWorkspaceId)
        guard stores.projects.get(projectId) != nil else { throw ProjectTransferError.refreshFailed }
        stores.touchProject(projectId)
        update(id) { $0.resultProjectId = projectId; $0.status = "succeeded"; $0.operation = operation; $0.error = nil }
    }

    private func wait(_ id: String, remote: ProjectSyncRemote, operation first: ProjectSyncOperation) async throws -> ProjectSyncOperation {
        var operation = first
        while true {
            try Task.checkCancellation()
            update(id) { $0.operation = operation }
            if !operation.active {
                guard operation.status == "succeeded" else { throw ProjectSyncFailure(operation: operation) }
                return operation
            }
            try await Task.sleep(for: .milliseconds(500))
            operation = try await remote.operation(operation.id)
        }
    }

    private func relay(_ id: String, source: ProjectSyncRemote, target: ProjectSyncRemote, checkpoint: ProjectSyncCheckpoint) async throws {
        var order: [ProjectSyncCheckpoint] = []
        var seen: Set<String> = []
        func collect(_ value: ProjectSyncCheckpoint) async throws {
            try Task.checkCancellation()
            guard seen.insert(value.id).inserted else { return }
            do { _ = try await target.checkpoint(value.id); return }
            catch let error as DaemonHTTPError where error.status == 404 { }
            for parent in value.parents { try await collect(source.checkpoint(parent)) }
            order.append(value)
        }
        try await collect(checkpoint)
        update(id) { $0.completedObjects = 0; $0.totalObjects = order.reduce(0) { $0 + $1.objectCount } }
        for checkpoint in order {
            var cursor = 0
            repeat {
                let page = try await source.objects(checkpoint.id, cursor: cursor)
                let missing = try await target.missing(page.objects)
                update(id) { $0.completedObjects += page.objects.count - missing.count }
                for object in missing {
                    try Task.checkCancellation()
                    let data = try await source.object(object)
                    try await target.putObject(object, data: data)
                    update(id) { $0.transferredBytes += Int64(data.count); $0.completedObjects += 1 }
                }
                cursor = page.next ?? 0
            } while cursor != 0
            try await target.accept(checkpoint)
        }
    }
}
