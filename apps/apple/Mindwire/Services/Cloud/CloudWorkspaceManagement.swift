import Foundation
import OblienKit

/// The SDK owns all cloud API requests and live log framing. This adapter provides the same
/// optional workspace controls contract used by the app's other providers.
actor CloudWorkspaceManagement: WorkspaceManagementService {
    nonisolated let features = Set(WorkspaceManagementFeature.allCases)
    nonisolated let workspaceId: String
    private nonisolated let client: OblienClient
    private nonisolated var handle: WorkspaceHandle { client.workspace(workspaceId) }
    private var runtime: RuntimeClient?

    init(workspaceId: String, client: OblienClient? = nil) {
        self.workspaceId = workspaceId; self.client = client ?? MindwireCloud.client
    }
    private func runtimeClient() async throws -> RuntimeClient {
        if let runtime { return runtime }
        let value = try await handle.runtime(enableIfNeeded: false)
        if let runtime { return runtime }
        runtime = value
        return value
    }

    func workspace() async throws -> ManagedWorkspace { try await ManagedWorkspace(handle.get()) }
    func workspaces() async throws -> [ManagedWorkspace] {
        var result: [ManagedWorkspace] = []
        var page = 1
        while true {
            let value = try await client.workspaces.list(.init(page: page, limit: 100))
            result += value.workspaces.map(ManagedWorkspace.init)
            if value.workspaces.isEmpty || result.count >= (value.total ?? result.count) { return result }
            page += 1
        }
    }
    func disks() async throws -> WorkspaceDiskList {
        let result = try await handle.disks.list()
        return .init(disks: result.disks.map(WorkspaceManagedDisk.init), operationId: result.operationId)
    }
    func allDisks() async throws -> [WorkspaceManagedDisk] { try await client.disks.list().map(WorkspaceManagedDisk.init) }
    func software() async throws -> [WorkspaceSoftware] { try await client.disks.listSoftware(workspaceId: workspaceId).map(WorkspaceSoftware.init) }
    func diskOperation(_ id: String) async throws -> WorkspaceDiskOperation { try await WorkspaceDiskOperation(client.disks.operation(id)) }
    func desktopInstallation() async throws -> WorkspaceDesktopInstallation { try await WorkspaceDesktopInstallation(handle.desktop.installation()) }
    func desktopStatus() async throws -> WorkspaceDesktopAccess {
        let status = try await runtimeClient().desktop.status()
        return .init(supported: status.supported, enabled: status.enabled, available: status.available, credentials: status.credentials)
    }
    func workloads() async throws -> [WorkspaceManagedWorkload] { try await handle.workloads.list().map(WorkspaceManagedWorkload.init) }
    func workloadTargets() async throws -> [WorkspaceExecutionTarget] {
        let discovery = try await runtimeClient().targets()
        return discovery.targets.map { target in
            let label: String
            switch target.id {
            case "local": label = "Workspace Host"
            case "macos": label = "macOS"
            case "windows": label = "Windows"
            case "linux": label = "Linux"
            default: label = target.id
            }
            return .init(id: target.id, label: label, available: target.available, isDefault: target.id == discovery.defaultTarget)
        }
    }
    nonisolated func workloadStatsStream() -> AsyncThrowingStream<[WorkspaceWorkloadMetrics], Error> {
        let events = handle.workloads.processStatsStream()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        try Task.checkCancellation()
                        continuation.yield(event.map(WorkspaceWorkloadMetrics.init))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func network() async throws -> WorkspaceNetwork { try await WorkspaceNetwork(handle.network.get()) }
    func outboundIPs() async throws -> [WorkspaceOutboundIP] { try await client.zones.mine().map { .init(ip: $0.ip, countryCode: $0.countryCode) } }
    func publicPorts() async throws -> [ExposedPort] {
        try await handle.publicAccess.list().map { .init(port: $0.port, url: $0.url ?? "", label: $0.label, slug: $0.slug) }
    }
    func domain() async throws -> WorkspaceDomain? { try await handle.domains.get().map(WorkspaceDomain.init) }
    func ssh() async throws -> WorkspaceSSHAccess { try await WorkspaceSSHAccess(handle.ssh.status()) }
    func runtimeAccess() async throws -> WorkspaceRuntimeAccess { try await .init(enabled: handle.runtimeAccess.status().enabled) }
    func lifecycle() async throws -> WorkspaceLifecycle { try await WorkspaceLifecycle(handle.lifecycle.get()) }
    func images() async throws -> [WorkspaceImageOption] {
        try await CloudImages.list()
    }
    func archives() async throws -> [WorkspaceArchive] {
        try await handle.snapshots.listArchives().map { .init(version: $0.version, name: $0.name, createdAt: $0.createdAt, sizeBytes: $0.sizeBytes ?? $0.size) }
    }
    func logConfig(_ id: String) async throws -> WorkspaceLogConfig { try await WorkspaceLogConfig(handle.workloads.logConfig(id)) }
    func logs(_ source: WorkspaceLogSource) async throws -> [WorkspaceLogEntry] {
        let batch: LogBatch
        switch source {
        case .boot: batch = try await handle.logs.entries()
        case .workload(let id): batch = try await handle.workloads.logEntries(id)
        }
        return WorkspaceLogEvent(batch).entries
    }
    nonisolated func logStream(_ source: WorkspaceLogSource) -> AsyncThrowingStream<WorkspaceLogEvent, Error> {
        let events: AsyncThrowingStream<LogBatch, Error>
        switch source {
        case .boot: events = handle.logs.follow()
        case .workload(let id): events = handle.workloads.followLogs(id)
        }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case .dropped = continuation.yield(WorkspaceLogEvent(event)) {
                            throw WorkspaceControlError(message: "Reconnect to load the latest retained logs.")
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func perform(_ command: WorkspaceManagementCommand) async throws -> WorkspaceManagementResult {
        switch command {
        case .retryCreation: _ = try await handle.retryCreation()
        case .disk(let action, let key): return .disk(try await performDisk(action, key: key))
        case .installDesktop(let choice, let restart):
            return .desktop(try await WorkspaceDesktopInstallation(handle.desktop.install(desktop: choice, restart: restart)))
        case .desktopAccess(let enabled):
            let desktop = try await runtimeClient().desktop
            if enabled { try await desktop.enable() } else { try await desktop.disable() }
        case .network(let patch): _ = try await handle.network.update(patch.sdkValue)
        case .outboundIP(let ip): try await handle.network.setOutboundIP(ip)
        case .createWorkload(let draft): _ = try await handle.workloads.create(Self.workloadParams(draft))
        case .updateWorkload(let id, let name, let restart, let limit):
            guard let policy = RestartPolicy(rawValue: restart), ["never", "on-failure", "always"].contains(restart), limit >= 0 else {
                throw WorkspaceControlError(message: "Choose a valid restart policy.")
            }
            _ = try await handle.workloads.patch(id, .init(name: name, restartPolicy: policy, maxRestarts: limit))
        case .workload(let id, let action):
            switch action {
            case .start: try await handle.workloads.start(id)
            case .stop: try await handle.workloads.stop(id)
            case .delete: try await handle.workloads.delete(id)
            }
        case .logRetention(let id, let sizeMb, let hours):
            try await handle.workloads.setLogRetention(id, maxLogSizeMb: sizeMb, logRetentionHours: hours)
        case .clearLogs(let id): try await handle.workloads.clearLogs(id)
        case .exposePort(let port, let label, let slug): _ = try await handle.publicAccess.expose(port: port, label: label, slug: slug)
        case .updatePortSlug(let port, let slug): try await handle.publicAccess.updateSlug(port: port, slug: slug)
        case .revokePort(let port): try await handle.publicAccess.revoke(port: port)
        case .checkDomain(let domain): return .domainCheck(try await WorkspaceDomainCheck(handle.domains.check(domain)))
        case .connectDomain(let domain, let port, let includeWww): _ = try await handle.domains.set(domain, port: port, includeWww: includeWww)
        case .removeDomain: try await handle.domains.remove()
        case .renewSSL: _ = try await handle.domains.renewSSL()
        case .sshAccess(let enabled):
            if enabled { return .ssh(try await WorkspaceSSHAccess(handle.ssh.enable())) }
            try await handle.ssh.disable()
        case .sshPassword(let password): try await handle.ssh.setPassword(password)
        case .sshPublicKey(let key): try await handle.ssh.setKey(publicKey: key)
        case .runtimeAccess(let enabled):
            if enabled { _ = try await handle.runtimeAccess.enable() } else { try await handle.runtimeAccess.disable() }
            await runtime?.invalidate()
        case .runtimeToken(let raw):
            return .credential(raw ? try await handle.runtimeAccess.rawToken().token : try await handle.runtimeAccess.getToken().token)
        case .rotateRuntimeToken:
            let token = try await handle.runtimeAccess.rotateToken().token
            await runtime?.invalidate()
            return .credential(token)
        case .identity(let name, let slug, let logo):
            _ = try await handle.update(.init(name: name, slug: slug, logo: logo, clearSlug: slug == nil, clearLogo: logo == nil))
        case .lifecycle(let mode, let restart, let maxRestarts, let ttl, let ttlAction, let remove):
            guard let policy = RestartPolicy(rawValue: restart), let action = TTLAction(rawValue: ttlAction) else {
                throw WorkspaceControlError(message: "Choose a valid lifecycle policy.")
            }
            if mode == "permanent" { try await handle.lifecycle.makePermanent(restartPolicy: policy) }
            else { try await handle.lifecycle.makeTemporary(ttl: ttl, ttlAction: action, removeOnExit: remove) }
            _ = try await handle.update(.init(config: .init(restartPolicy: policy, maxRestarts: maxRestarts)))
        case .idle(let suspend, let stop): try await handle.lifecycle.setIdle(suspendAfter: suspend, stopAfter: stop)
        case .pause: try await handle.pause()
        case .resume: try await handle.resume()
        case .hibernate: try await handle.snapshots.snapshot(after: "stop")
        case .restore: try await handle.snapshots.restore()
        case .reinstall: try await handle.reinstall()
        case .createArchive(let version, let paths, let excludes):
            try await handle.snapshots.createArchive(.init(version: version, format: "tar", vmPaths: paths, excludeVmPaths: excludes))
        case .deleteArchive(let version): try await handle.snapshots.deleteArchive(version, deleteFile: true)
        case .renewTTL: try await handle.ping()
        }
        return .completed
    }

    static func workloadParams(_ draft: WorkspaceWorkloadDraft) throws -> WorkloadCreateParams {
        guard !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceControlError(message: "Enter the command to run.") }
        var keys = Set<String>()
        let environment = try draft.environment.map { variable -> EnvVar in
            guard variable.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  keys.insert(variable.key).inserted else { throw WorkspaceControlError(message: "Environment variable names must be valid and unique.") }
            return .init(key: variable.key, value: variable.value)
        }
        guard let policy = RestartPolicy(rawValue: draft.restartPolicy) else { throw WorkspaceControlError(message: "Choose a restart policy.") }
        return .init(name: draft.name.isEmpty ? nil : draft.name, cmd: ["/bin/sh", "-lc", draft.command], env: environment,
                     restartPolicy: policy, maxRestarts: draft.maxRestarts,
                     workingDir: draft.directory.isEmpty ? nil : draft.directory, target: draft.target.isEmpty ? nil : draft.target,
                     maxLogSizeMb: draft.maxLogSizeMb == 10 ? nil : draft.maxLogSizeMb,
                     logRetentionHours: draft.logRetentionHours == 168 ? nil : draft.logRetentionHours)
    }

    private func performDisk(_ action: WorkspaceDiskAction, key: String) async throws -> WorkspaceDiskResult {
        let options = DiskOperationOptions(idempotencyKey: key)
        let disks = client.disks
        if let size = action.sizeMb, !(64...1_048_576).contains(size) { throw WorkspaceControlError(message: "Disk capacity must be between 64 MiB and 1 TiB.") }
        if let path = action.mountPath, !WorkspaceControlValidation.mountPath(path) { throw WorkspaceControlError(message: "Choose an absolute mount directory outside system folders, such as /data/project.") }
        let value: DiskMutationResult
        switch action.kind {
        case .create:
            guard let size = action.sizeMb, let name = action.name else { throw WorkspaceControlError(message: "Enter a disk name and capacity.") }
            value = try await disks.create(.init(name: name, sizeMb: size, format: action.format, namespace: action.namespace), options: options)
        case .retain: value = try await handle.disks.retainRoot(name: action.name, options: options)
        case .discardSavedExecution: value = try await handle.disks.discardSavedExecution(options: options)
        case .retry:
            guard let id = action.operationId else { throw WorkspaceControlError(message: "Choose an operation to retry.") }
            value = try await disks.retry(id, options: options)
        default:
            guard let id = action.diskId else { throw WorkspaceControlError(message: "Choose a disk first.") }
            switch action.kind {
            case .attachSoftware: value = try await disks.attachSoftware(id, workspaceId: workspaceId, options: options)
            case .attach:
                value = try await disks.attach(id, .init(workspaceId: workspaceId,
                    mountPath: action.mountPath?.isEmpty == true ? nil : action.mountPath,
                    readOnly: action.readOnly, role: action.role, target: action.target), options: options)
            case .detach: value = try await disks.detach(id, workspaceId: workspaceId, options: options)
            case .move:
                guard let target = action.targetWorkspaceId, target != workspaceId else { throw WorkspaceControlError(message: "Choose another stopped workspace.") }
                // The picker filters eligible destinations; the server checks them atomically.
                // Replaying the same key must still recover an already-accepted move.
                value = try await disks.move(id, sourceWorkspaceId: workspaceId, targetWorkspaceId: target, mountPath: action.mountPath, options: options)
            case .delete: value = try await disks.delete(id, options: options)
            case .clone: value = try await disks.clone(id, name: action.name, options: options)
            case .save: value = try await disks.save(id, name: action.name, options: options)
            case .fork:
                guard let size = action.sizeMb else { throw WorkspaceControlError(message: "Enter a capacity.") }
                value = try await disks.fork(id, sizeMb: size, name: action.name, options: options)
            case .resize:
                guard let size = action.sizeMb else { throw WorkspaceControlError(message: "Enter a capacity.") }
                value = try await disks.resize(id, sizeMb: size, options: options)
            default: throw WorkspaceControlError(message: "This disk action is unavailable.")
            }
        }
        return WorkspaceDiskResult(value)
    }
}
