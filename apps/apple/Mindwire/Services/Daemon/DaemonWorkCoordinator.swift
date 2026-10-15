import Foundation
import Observation

/// A daemon belongs to a workspace; a CLI installation belongs to a harness in that workspace.
/// Local agent/persona IDs must never be used as install locks.
struct DaemonWorkKey: Hashable {
    let workspaceId: String
    var agentType: String? = nil
}

@MainActor @Observable
final class DaemonWorkState {
    var running = false
    var activity: PrepActivity = .checking
    var message: String?
    var progress: Double = 0
    var installProgress: DaemonInstallProgress?
    @ObservationIgnored private var progressGeneration = UUID()
    var steps: [DaemonStepResult] = []
    var plan: [String] = []
    var currentStep: String?
    var startedAt: Date?
    var error: String?
    var installedVersion: String?
    var latestVersion: String?
    var updateWaiting = false
    var updateOperation: DaemonServiceUpdateOperation?
    var updateCheckError: String?
    /// A queued update and its read-only polls are not installation work.
    var changingService: Bool {
        running && (activity == .installingDaemon || activity == .updatingDaemon)
            && installProgress != nil && installProgress?.phase != DaemonInstallProgress.waiting.phase
    }
    var software: DaemonHarnessSoftware?
    var softwareCheckedAt: Date?
    var softwareRefreshing = false
    var health: DaemonHealth?
    var checkedAt: Date?
    /// nil after a cold launch: persisted versions are useful, but are not a connectivity check.
    var reachable: Bool?
    var connectionError: String?
    /// Management-API state is separate from daemon connectivity and is never persisted.
    var workspaceStatus: WorkspaceStatus?
    var powerAction: PowerAction?
    var powerError: String?

    var workspaceUnavailable: Bool { powerAction != nil || workspaceStatus?.power.blocksService == true }
    /// Live harness authentication, shared by every persona in this workspace; never persisted.
    var authentication: DaemonAuthStatus?
    var authenticationCheckedAt: Date?
    /// A running job invalidates readiness for every persona. Completion alone is not proof
    /// that the CLI can run; /agent must verify it before any page exposes agent controls.
    var requiresVerification = false

    var supportsProjects: Bool {
        guard let health else { return false }
        return health.ok && (health.workspaceMetadataVersion ?? 0) >= 1 && (health.projectOperationsVersion ?? 0) >= 1
    }

    var canCreateProjects: Bool { !workspaceUnavailable && reachable == true && supportsProjects && !running }

    var completedStepCount: Int {
        Set(steps.filter { ($0.status == "installed" || $0.status == "satisfied") && plan.contains($0.name) }
            .map(\.name)).count
    }

    /// Tool setup measures completed tools, while service downloads measure bytes. A missing
    /// plan on an older daemon stays indeterminate; it must not inherit the service's 100%.
    var progressFraction: Double? {
        if !plan.isEmpty { return Double(completedStepCount) / Double(plan.count) }
        if let installProgress { return installProgress.transferFraction }
        return progress > 0 ? progress : nil
    }

    var updateAvailable: Bool {
        if let software { return software.canUpdate }
        guard let installedVersion, let latestVersion else { return false }
        return latestVersion.compare(installedVersion, options: .numeric) == .orderedDescending
    }

    func begin(_ activity: PrepActivity) {
        running = true
        self.activity = activity
        message = nil
        progress = 0
        installProgress = nil
        progressGeneration = UUID()
        steps = []
        plan = []
        currentStep = nil
        startedAt = nil
        error = nil
        requiresVerification = true
    }

    func receive(_ status: DaemonSetupResult) {
        running = status.running == true
        if running || (status.started == true && !status.ok) { requiresVerification = true }
        if status.operation == "update" { activity = .updatingTools }
        else if status.operation == "setup" || activity != .updatingTools { activity = .installingTools }
        steps = status.steps
        plan = status.plan ?? []
        currentStep = status.current.flatMap { $0.isEmpty ? nil : $0 }
        if let timestamp = status.startedAt {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            startedAt = parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        } else { startedAt = nil }
        message = currentStep
        if let name = message, let stage = status.stage,
           ["checking", "waiting", "installing", "resolving", "downloading", "configuring", "verifying"].contains(stage) {
            message = t("agentUpdates.step.\(stage)", ["name": name])
        }
        if running || status.ok { error = nil }
        else if status.started == true {
            error = status.steps.first(where: { $0.status == "failed" })?.output ?? t("agentAuth.stage.setupFailed")
        }
    }

    func receive(_ update: DaemonInstallProgress) {
        guard running else { return }
        if let installProgress, update.phase < installProgress.phase { return }
        installProgress = update
        progress = update.fraction
        message = update.message
    }

    /// Transfer callbacks may be delivered after the installer returns. Keep them scoped to
    /// the operation that created them, including when a retry has already started.
    func progressHandler() -> @Sendable (DaemonInstallProgress) -> Void {
        let generation = progressGeneration
        return { [weak self] progress in
            Task { @MainActor in
                guard let self, self.progressGeneration == generation else { return }
                self.receive(progress)
            }
        }
    }
}

@MainActor @Observable
final class DaemonWorkCoordinator {
    static let shared = DaemonWorkCoordinator()
    private(set) var states: [DaemonWorkKey: DaemonWorkState] = [:]
    @ObservationIgnored private var jobs: [DaemonWorkKey: Task<Void, Error>] = [:]
    @ObservationIgnored private var reads: [DaemonWorkKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var softwareReads: [DaemonWorkKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var updateReads: [DaemonWorkKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var updateChecks: [DaemonWorkKey: (revision: Int, at: Date)] = [:]
    @ObservationIgnored private var checked: [DaemonWorkKey: Date] = [:]
    @ObservationIgnored private var revisions: [DaemonWorkKey: Int] = [:]
    @ObservationIgnored private var healthRevisions: [DaemonWorkKey: Int] = [:]
    @ObservationIgnored private var workspaceChecks: [DaemonWorkKey: RefreshState] = [:]
    @ObservationIgnored private var workspaceReads: [DaemonWorkKey: Task<WorkspaceStatus, Error>] = [:]
    @ObservationIgnored private var workspaceReadTickets: [DaemonWorkKey: UUID] = [:]
    @ObservationIgnored private var startupJobs: [DaemonWorkKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var startupFailures: [DaemonWorkKey: Date] = [:]
    @ObservationIgnored private var recoveryFailures: [DaemonWorkKey: Date] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var latestRelease: String?
    private static let cacheKey = "mindwire:workspace-daemons:v1"
    private static let startupKey = "mindwire:workspace-startup:v1"

    private struct CachedDaemon: Codable {
        var health: DaemonHealth?
        var installedVersion: String?
        var latestVersion: String?
        var checkedAt: Date?
        var update: CachedUpdate?
    }

    /// Keep the accepted receipt across relaunch, not a cached claim about current
    /// activity or connectivity. The next probe observes it on the computer again.
    private struct CachedUpdate: Codable {
        let id: String
        let version: String
        let status: String
        let force: Bool?
        let updatedAt: String?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let cached = defaults.data(forKey: Self.cacheKey)
            .flatMap { try? JSONDecoder().decode([String: CachedDaemon].self, from: $0) } ?? [:]
        for (id, value) in cached {
            let state = DaemonWorkState()
            state.health = value.health
            state.installedVersion = value.installedVersion
            state.latestVersion = value.latestVersion
            state.checkedAt = value.checkedAt
            if let update = value.update {
                state.updateOperation = .init(id: update.id, version: update.version,
                                              status: update.status, force: update.force, updatedAt: update.updatedAt)
            }
            states[.init(workspaceId: id)] = state
        }
    }

    func probeRevision(_ key: DaemonWorkKey) -> Int { revisions[key, default: 0] }

    /// One migration per workspace, persisted across app launches. Normal navigation
    /// does not re-register workloads or services, and a failed optional migration
    /// cannot make a healthy service unavailable.
    func configureStartupIfNeeded(_ key: DaemonWorkKey, operation: @escaping () async throws -> Void) {
        guard key.agentType == nil, startupJobs[key] == nil,
              !(defaults.stringArray(forKey: Self.startupKey) ?? []).contains(key.workspaceId),
              startupFailures[key].map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        startupJobs[key] = Task {
            defer { startupJobs[key] = nil }
            do {
                try await operation()
                try Task.checkCancellation()
                var registered = Set(defaults.stringArray(forKey: Self.startupKey) ?? [])
                registered.insert(key.workspaceId)
                defaults.set(Array(registered), forKey: Self.startupKey)
                startupFailures[key] = nil
            } catch {
                startupFailures[key] = Date()
                if !error.isRequestCancellation { APILog.note("service startup registration: \(error.localizedDescription.oneLine())") }
            }
        }
    }

    func canRecoverService(_ key: DaemonWorkKey) -> Bool {
        recoveryFailures[key].map { Date().timeIntervalSince($0) >= 60 } ?? true
    }

    func serviceRecoveryFailed(_ key: DaemonWorkKey) { recoveryFailures[key] = Date() }

    /// Release discovery is global. Updating its version does not invalidate healthy
    /// workspace checks, and an older passive read cannot roll it back afterwards.
    func recordLatestRelease(_ version: String) {
        latestRelease = version
        for (key, state) in states where key.agentType == nil {
            state.latestVersion = version
            if !state.updateAvailable { state.updateWaiting = false }
        }
        persist()
    }

    func hasActiveWork(workspaceId: String) -> Bool {
        jobs.keys.contains { $0.workspaceId == workspaceId }
    }

    func freshHealth(for key: DaemonWorkKey, at now: Date = Date(), maxAge: TimeInterval = 60) -> DaemonHealth? {
        guard jobs[key] == nil, let state = states[key], !state.running, state.reachable == true,
              healthRevisions[key] == revisions[key, default: 0], let checkedAt = state.checkedAt,
              now.timeIntervalSince(checkedAt) >= 0, now.timeIntervalSince(checkedAt) < maxAge else { return nil }
        return state.health
    }

    /// Keep the last known value visible, but require a new probe after a runtime change or error.
    func invalidateChecks(_ key: DaemonWorkKey) {
        revisions[key, default: 0] += 1
        checked[key] = nil
        recoveryFailures[key] = nil
        startupFailures[key] = nil
    }

    func invalidateWorkspaceStatus(_ key: DaemonWorkKey) {
        workspaceChecks[key, default: RefreshState()].invalidate()
        workspaceReads.removeValue(forKey: key)?.cancel()
        workspaceReadTickets[key] = nil
    }

    /// The detail page and service preflight share one lightweight management check. Runtime
    /// proxy errors force this check again, because a stopped VM cannot answer its own healthz.
    func readWorkspaceStatus(for key: DaemonWorkKey, force: Bool = false, at now: Date = Date(),
                             read: @escaping @MainActor () async throws -> WorkspaceStatus) async throws -> WorkspaceStatus {
        if let pending = workspaceReads[key] {
            do { return try await pending.value }
            catch is CancellationError {
                try Task.checkCancellation()
                return try await readWorkspaceStatus(for: key, force: force, at: now, read: read)
            }
        }
        let state = state(for: key)
        if !force, let status = state.workspaceStatus,
           workspaceChecks[key]?.isFresh(at: now, maxAge: status.power.isTransitioning || state.powerAction != nil ? 2 : 60) == true {
            return status
        }
        let revision = workspaceChecks[key, default: RefreshState()].revision
        let ticket = UUID()
        let task = Task {
            defer {
                if workspaceReadTickets[key] == ticket { workspaceReads[key] = nil; workspaceReadTickets[key] = nil }
            }
            let status = try await read()
            try Task.checkCancellation()
            guard workspaceChecks[key, default: RefreshState()].revision == revision else { throw CancellationError() }
            recordWorkspaceStatus(status, for: key)
            workspaceChecks[key, default: RefreshState()].finish(success: true, at: now, revision: revision)
            return status
        }
        workspaceReads[key] = task
        workspaceReadTickets[key] = ticket
        return try await task.value
    }

    func recordWorkspaceStatus(_ status: WorkspaceStatus, for key: DaemonWorkKey) {
        let state = state(for: key)
        if state.workspaceStatus?.power != status.power {
            invalidateChecks(key)
            // No pre-boot result proves that the service in the new VM is ready.
            state.reachable = nil
            state.connectionError = nil
        }
        state.workspaceStatus = status
        if status.power.blocksService { state.reachable = false; state.connectionError = nil }
    }

    func beginPowerAction(_ action: PowerAction, for key: DaemonWorkKey) {
        invalidateWorkspaceStatus(key)
        invalidateChecks(key)
        let state = state(for: key)
        state.powerAction = action
        state.powerError = nil
        state.reachable = nil
        state.connectionError = nil
    }

    func finishPowerAction(for key: DaemonWorkKey, error: String? = nil) {
        guard let state = states[key] else { return }
        state.powerAction = nil
        state.powerError = error
    }

    func recordHealth(_ health: DaemonHealth, for key: DaemonWorkKey, latest: String? = nil, revision: Int? = nil) {
        if let revision, jobs[key] != nil || revisions[key, default: 0] != revision { return }
        let state = state(for: key)
        let versionChanged = health.version.map { state.installedVersion != nil && state.installedVersion != $0 } ?? false
        if state.reachable != health.ok || versionChanged {
            revisions[key, default: 0] += 1
        }
        state.health = health
        state.reachable = health.ok
        if health.ok { recoveryFailures[key] = nil }
        state.connectionError = health.ok ? nil : t("workspace.daemon.unreachable")
        if health.ok && state.activity == .checking { state.error = nil }
        if let version = health.version { state.installedVersion = version }
        if var operation = state.updateOperation, operation.isActive,
           health.ok, DaemonRelease.satisfies(health.version, target: operation.version) {
            operation.status = "complete"
            operation.activity = nil
            operation.observationError = nil
            state.updateOperation = operation
        }
        if let latest = (key.agentType == nil ? latestRelease : nil) ?? latest { state.latestVersion = latest }
        if !state.updateAvailable { state.updateWaiting = false }
        state.checkedAt = Date()
        healthRevisions[key] = revisions[key, default: 0]
        persist()
    }

    func recordFailure(_ error: Error, for key: DaemonWorkKey, revision: Int) {
        guard !error.isRequestCancellation, jobs[key] == nil, revisions[key, default: 0] == revision else { return }
        let state = state(for: key)
        if state.reachable != false { revisions[key, default: 0] += 1 }
        state.reachable = false
        state.connectionError = error.localizedDescription
        state.checkedAt = Date()
        persist()
    }

    /// Keep the controller's durable outcome visible after polling/screens finish.
    /// A slow check cannot overwrite an update started while it was in flight.
    func recordUpdateOperation(_ operation: DaemonServiceUpdateOperation?, for key: DaemonWorkKey, revision: Int) {
        guard jobs[key] == nil, revisions[key, default: 0] == revision else { return }
        let state = state(for: key)
        state.updateOperation = operation
        state.updateCheckError = nil
        updateChecks[key] = (revision, Date())
        if let operation {
            state.activity = .updatingDaemon
            state.updateWaiting = operation.status == "waiting"
            if operation.status == "failed" { state.error = operation.error ?? t("workspace.daemon.updateFailed") }
            else if operation.status == "complete" || operation.isActive { state.error = nil }
        }
        persist()
    }

    func recordUpdateCheckFailure(_ error: Error, for key: DaemonWorkKey, revision: Int) {
        guard jobs[key] == nil, revisions[key, default: 0] == revision else { return }
        state(for: key).updateCheckError = error.localizedDescription
        updateChecks[key] = (revision, Date())
    }

    func refreshUpdateOperation(_ key: DaemonWorkKey,
                                read: @escaping () async throws -> DaemonServiceUpdateOperation?) async {
        guard jobs[key] == nil else { return }
        if let pending = updateReads[key] {
            await pending.value
            if updateChecks[key]?.revision != revisions[key, default: 0] {
                await refreshUpdateOperation(key, read: read)
            }
            return
        }
        let revision = revisions[key, default: 0]
        let interval: TimeInterval = states[key]?.updateOperation?.isActive == true ? 3 : 60
        if let check = updateChecks[key], check.revision == revision,
           Date().timeIntervalSince(check.at) >= 0, Date().timeIntervalSince(check.at) < interval { return }
        let task = Task {
            defer { updateReads[key] = nil }
            do { recordUpdateOperation(try await read(), for: key, revision: revision) }
            catch { recordUpdateCheckFailure(error, for: key, revision: revision) }
        }
        updateReads[key] = task
        await task.value
    }

    func recordOperationFailure(_ error: Error, for key: DaemonWorkKey, activity: PrepActivity) {
        guard jobs[key] == nil else { return }
        let state = state(for: key)
        state.activity = activity
        state.error = error.localizedDescription
    }

    func recordAuthentication(_ status: DaemonAuthStatus, for key: DaemonWorkKey) {
        // A slow passive read must not undo a login just confirmed by the auth form.
        revisions[key, default: 0] += 1
        authenticationRevisions[key, default: 0] += 1
        let state = state(for: key)
        state.authentication = status
        state.authenticationCheckedAt = Date()
    }

    private var authenticationRevisions: [DaemonWorkKey: Int] = [:]
    func authenticationRevision(for key: DaemonWorkKey) -> Int { authenticationRevisions[key, default: 0] }

    func recordAgentInfo(_ info: DaemonAgentInfo, for key: DaemonWorkKey) {
        // A probe started before a new install must not verify that newer job with an old CLI.
        guard jobs[key] == nil, states[key]?.running != true else { return }
        revisions[key, default: 0] += 1
        let state = state(for: key)
        let version = info.installedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        state.installedVersion = version.isEmpty ? nil : version
        state.software = info.software
        state.requiresVerification = version.isEmpty
        state.error = version.isEmpty ? t("agentUpdates.verifyFailed") : nil
        if let status = info.authStatus {
            state.authentication = status
            state.authenticationCheckedAt = Date()
        }
    }

    /// One catalog check per workspace/harness, shared by every persona and screen. Ordinary
    /// navigation uses its five-minute result; manual refresh bypasses this client cache.
    func refreshSoftware(_ key: DaemonWorkKey, force: Bool = false,
                         read: @escaping @MainActor () async throws -> DaemonHarnessSoftware?) async {
        guard jobs[key] == nil else { return }
        if let pending = softwareReads[key] { await pending.value; return }
        let state = state(for: key)
        if !force, let at = state.softwareCheckedAt, Date().timeIntervalSince(at) < 300 { return }
        let revision = revisions[key, default: 0]
        state.softwareRefreshing = true
        let task = Task {
            defer { softwareReads[key] = nil; state.softwareRefreshing = false }
            do {
                let info = try await read()
                guard jobs[key] == nil, revisions[key, default: 0] == revision else { return }
                state.software = info
                state.softwareCheckedAt = Date()
            } catch {
                // Retain the last daemon decision; a transient read must not advertise a new
                // update or replace a supported version with an unavailable state.
                state.softwareCheckedAt = Date().addingTimeInterval(-270)
            }
        }
        softwareReads[key] = task
        await task.value
    }

    /// A one-shot read can observe a remote job completing after the last live badge update.
    /// Clear that stale running flag before /agent verifies it, without finishing an owned job.
    func recordPreparation(_ status: DaemonSetupResult, for key: DaemonWorkKey, revision: Int) {
        guard jobs[key] == nil, revisions[key, default: 0] == revision else { return }
        revisions[key, default: 0] += 1
        state(for: key).receive(status)
    }

    func forget(workspaceId: String) {
        let registered = (defaults.stringArray(forKey: Self.startupKey) ?? []).filter { $0 != workspaceId }
        defaults.set(registered, forKey: Self.startupKey)
        for key in startupJobs.keys.filter({ $0.workspaceId == workspaceId }) {
            startupJobs.removeValue(forKey: key)?.cancel()
        }
        for key in Set(states.keys).union(revisions.keys).filter({ $0.workspaceId == workspaceId }) {
            revisions[key, default: 0] += 1
            states[key] = nil
            checked[key] = nil
            healthRevisions[key] = nil
            updateChecks[key] = nil
            startupFailures[key] = nil
            recoveryFailures[key] = nil
            invalidateWorkspaceStatus(key)
        }
        persist()
    }

    private func persist() {
        let cache = Dictionary(uniqueKeysWithValues: states.compactMap { key, state -> (String, CachedDaemon)? in
            guard key.agentType == nil else { return nil }
            let pending = state.updateOperation.flatMap { operation in
                operation.isActive ? CachedUpdate(id: operation.id, version: operation.version,
                    status: operation.status, force: operation.force, updatedAt: operation.updatedAt) : nil
            }
            return (key.workspaceId, CachedDaemon(health: state.health, installedVersion: state.installedVersion,
                                                  latestVersion: state.latestVersion, checkedAt: state.checkedAt, update: pending))
        })
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: Self.cacheKey) }
    }

    @discardableResult
    func join(_ key: DaemonWorkKey) async throws -> Bool {
        guard let job = jobs[key] else { return false }
        try await job.value
        return true
    }

    /// The task outlives any individual screen. Every caller awaits the same job, and failed jobs
    /// release their lock before callers resume so an explicit retry can start immediately.
    func perform(_ key: DaemonWorkKey, activity: PrepActivity = .checking,
                 operation: @escaping @MainActor (DaemonWorkState) async throws -> Void) async throws {
        if let job = jobs[key] { return try await job.value }
        let state = state(for: key)
        revisions[key, default: 0] += 1
        checked[key] = nil
        state.begin(activity)
        let job = Task {
            defer { jobs[key] = nil; state.running = false; persist() }
            do { try await operation(state) }
            catch {
                if let pending = error as? DaemonUpdatePending {
                    state.error = nil
                    state.updateOperation = pending.operation
                    state.updateWaiting = pending.operation.status == "waiting"
                } else if error as? DaemonUpdateError == .busy {
                    state.error = nil
                    state.updateWaiting = true
                } else { state.error = error.localizedDescription }
                throw error
            }
        }
        jobs[key] = job
        try await job.value
    }

    enum Snapshot {
        case setup(DaemonSetupResult, authentication: DaemonAuthStatus? = nil)
        case daemon(installed: String?, latest: String?)
        case workspace(health: DaemonHealth, latest: String?)
    }

    /// Passive, throttled reads detect work started by another client. A slow read cannot overwrite
    /// progress from a newer local job. Several rows sharing a workspace/harness share this request.
    func refresh(_ key: DaemonWorkKey, interval: TimeInterval,
                 read: @escaping @MainActor () async throws -> Snapshot) async {
        if jobs[key] != nil { return }
        if let pending = reads[key] { await pending.value; return }
        if let last = checked[key], Date().timeIntervalSince(last) < interval { return }
        checked[key] = Date()
        let revision = revisions[key, default: 0]
        let task = Task {
            defer { reads[key] = nil }
            do {
                let snapshot = try await read()
                guard jobs[key] == nil, revisions[key, default: 0] == revision else { return }
                let state = state(for: key)
                switch snapshot {
                case .setup(let status, let authentication):
                    state.receive(status)
                    if let authentication {
                        state.authentication = authentication
                        state.authenticationCheckedAt = Date()
                    }
                case .daemon(let installed, let latest):
                    if let installed { state.installedVersion = installed }
                    if let latest = (key.agentType == nil ? latestRelease : nil) ?? latest { state.latestVersion = latest }
                    persist()
                case .workspace(let health, let latest):
                    recordHealth(health, for: key, latest: latest, revision: revision)
                }
            } catch {
                // Offline is unknown, not a completed update. Keep the last known job state.
            }
        }
        reads[key] = task
        await task.value
    }

    private func state(for key: DaemonWorkKey) -> DaemonWorkState {
        if let state = states[key] { return state }
        let state = DaemonWorkState()
        if key.agentType == nil { state.latestVersion = latestRelease }
        states[key] = state
        return state
    }
}
