import XCTest
@testable import Mindwire

@MainActor
final class ServiceReleaseCheckTests: XCTestCase {
    private func stores() throws -> Stores {
        let suite = "MindwireTests.service-release.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func workspace(_ id: String) -> Workspace {
        .init(id: id, name: id, runtime: .server(serverId: id), createdAt: "now")
    }

    private func catalog(_ version: String) -> DaemonCatalog {
        .init(version: version, agents: [.init(id: .codex, name: "Codex", tagline: "Coding")])
    }

    private func health(_ version: String = "0.1.19") -> DaemonHealth {
        .init(ok: true, version: version, workspaceMetadataVersion: 1,
              projectOperationsVersion: 1, serviceUpdateVersion: 1)
    }

    func testLaunchChecksFreshPersistedCatalogThenThrottlesWithoutInvalidatingWorkspaceHealth() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let key = DaemonWorkKey(workspaceId: "laptop")
        coordinator.recordHealth(health(), for: key, latest: "0.1.19")
        let checkedAt = coordinator.states[key]?.checkedAt
        let revision = coordinator.probeRevision(key)
        var version = "0.1.19", calls = 0, date = Date()
        let source = ReleaseCatalog(defaults: stores.defaults, fetch: {
            calls += 1
            return self.catalog(version)
        })
        _ = try await source.load()
        version = "0.1.21"
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, now: { date }, fetchCatalog: {
            try await source.load(maxAge: 0, allowStale: false)
        })
        let initial = await queue.refreshRelease()
        XCTAssertTrue(initial)
        XCTAssertEqual(calls, 2, "A picker cache from the previous launch must not suppress update discovery")
        XCTAssertEqual(coordinator.states[key]?.latestVersion, "0.1.21")
        XCTAssertEqual(coordinator.states[key]?.checkedAt, checkedAt)
        XCTAssertEqual(coordinator.probeRevision(key), revision)
        XCTAssertNotNil(coordinator.freshHealth(for: key))
        for _ in 0..<10 { await queue.refreshRelease() }
        XCTAssertEqual(calls, 2)
        date.addTimeInterval(301)
        version = "0.1.22"
        await queue.refreshRelease()
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(queue.latestVersion, "0.1.22")
        let reloaded = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, fetchCatalog: {
            try await source.load(maxAge: 0, allowStale: false)
        })
        await reloaded.refreshRelease()
        XCTAssertEqual(calls, 4, "A new app launch checks again even with a fresh disk cache")
    }

    func testOlderPassiveVersionCannotOverwriteFreshGlobalReleaseOrHarnessVersion() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try stores().defaults)
        let key = DaemonWorkKey(workspaceId: "workspace")
        let harness = DaemonWorkKey(workspaceId: "workspace", agentType: "codex")
        await coordinator.refresh(harness, interval: 0) { .daemon(installed: "3.0.0", latest: "3.1.0") }
        coordinator.recordLatestRelease("0.1.21")
        coordinator.recordHealth(health(), for: key, latest: "0.1.19")
        await coordinator.refresh(key, interval: 0) { .daemon(installed: nil, latest: "0.1.19") }
        XCTAssertEqual(coordinator.states[key]?.latestVersion, "0.1.21")
        XCTAssertEqual(coordinator.states[key]?.installedVersion, "0.1.19")
        XCTAssertEqual(coordinator.states[harness]?.latestVersion, "3.1.0")
    }

    func testFailedCheckNeverReportsSuccessAndManualRetryBypassesCooldown() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let workspace = workspace("offline-check")
        coordinator.recordHealth(health(), for: .init(workspaceId: workspace.id))
        var calls = 0, offline = true, reads = 0
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true },
            update: { _, _, _ in XCTFail("An unverified release must never start an update") }, fetchCatalog: {
                calls += 1
                if offline { throw URLError(.notConnectedToInternet) }
                return self.catalog("0.1.21")
            }, readWorkspace: { _ in reads += 1 })
        let failed = await queue.refreshRelease()
        XCTAssertFalse(failed)
        XCTAssertNotNil(queue.releaseCheckError)
        XCTAssertNil(queue.releaseCheckedAt)
        await queue.refreshRelease()
        XCTAssertEqual(calls, 1)
        let update = await queue.updateAll([workspace])
        XCTAssertFalse(update)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(queue.requested.isEmpty)
        offline = false
        let retry = await queue.checkUpdates([workspace])
        XCTAssertTrue(retry)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(queue.latestVersion, "0.1.21")
        XCTAssertNotNil(queue.releaseCheckedAt)
        XCTAssertNil(queue.releaseCheckError)
        XCTAssertTrue(queue.requested.isEmpty, "Checking alone does not request installation")
    }

    func testConcurrentManualChecksShareReleaseAndWorkspaceReads() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let workspace = workspace("shared")
        var releaseGate: CheckedContinuation<Void, Never>?
        var workspaceGate: CheckedContinuation<Void, Never>?
        var releases = 0, reads = 0
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, fetchCatalog: {
            releases += 1
            await withCheckedContinuation { releaseGate = $0 }
            return self.catalog("0.1.21")
        }, readWorkspace: { _ in
            reads += 1
            await withCheckedContinuation { workspaceGate = $0 }
        })
        let first = Task { await queue.checkUpdates([workspace]) }
        try await eventually { releaseGate != nil }
        releaseGate?.resume()
        try await eventually { workspaceGate != nil }
        // Repeating a check after release discovery, while a slower workspace is being
        // read, must still join the full operation instead of fetching the release again.
        let second = Task { await queue.checkUpdates([workspace]) }
        await Task.yield()
        XCTAssertTrue(queue.checking)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(reads, 1)
        workspaceGate?.resume()
        let a = await first.value, b = await second.value
        XCTAssertTrue(a && b)
        XCTAssertFalse(queue.checking)
    }

    func testUpdateAllHonorsManualIntentWhileBusyAndOfflineWorkspacesWait() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        stores.defaults.set(false, forKey: StorageKey.automaticServiceUpdates)
        let workspaces = ["idle", "busy", "offline", "stopped", "current"].map(workspace)
        for workspace in workspaces {
            coordinator.recordHealth(health(workspace.id == "current" ? "0.1.21" : "0.1.19"),
                for: .init(workspaceId: workspace.id), latest: "0.1.19")
        }
        let offlineKey = DaemonWorkKey(workspaceId: "offline")
        coordinator.recordFailure(URLError(.cannotConnectToHost), for: offlineKey, revision: coordinator.probeRevision(offlineKey))
        coordinator.recordWorkspaceStatus(.init(power: .stopped), for: .init(workspaceId: "stopped"))
        var busy = true, calls: [String: Int] = [:], date = Date()
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, now: { date },
            update: { id, automatic, _ in
                XCTAssertFalse(automatic)
                calls[id, default: 0] += 1
                if id == "busy", busy { throw DaemonUpdateError.busy }
                coordinator.recordHealth(self.health("0.1.21"), for: .init(workspaceId: id))
            }, fetchCatalog: { self.catalog("0.1.21") }, readWorkspace: { _ in })
        await queue.updateAll(workspaces)
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(calls, ["idle": 1, "busy": 1])
        XCTAssertEqual(queue.requested, ["busy", "offline", "stopped"])
        XCTAssertEqual(queue.waitingCount, 3)
        XCTAssertNil(coordinator.states[.init(workspaceId: "busy")]?.error)
        busy = false
        date.addTimeInterval(16)
        queue.reconcile(workspaces)
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(calls["busy"], 2)
        coordinator.recordHealth(health(), for: offlineKey)
        queue.reconcile(workspaces)
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(calls["offline"], 1)
        XCTAssertNil(calls["stopped"], "Update All must never power on a stopped workspace")
        XCTAssertNil(calls["current"], "No install is needed for the current release")
        XCTAssertEqual(queue.requested, ["stopped"])
        queue.forget(workspaceId: "stopped")
    }

    func testBulkUpdatesAreBoundedAndRepeatedActionsDoNotDuplicateAnInstall() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let workspaces = (0..<5).map { workspace("workspace-\($0)") }
        for workspace in workspaces { coordinator.recordHealth(health(), for: .init(workspaceId: workspace.id)) }
        var gates: [String: CheckedContinuation<Void, Never>] = [:]
        var calls: [String: Int] = [:], reads: [String: Int] = [:], releases = 0, parallel = 0, peak = 0
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, update: { id, _, target in
            XCTAssertEqual(target, "0.1.21", "The batch's verified release is reused by each workspace")
            calls[id, default: 0] += 1
            parallel += 1; peak = max(peak, parallel)
            await withCheckedContinuation { gates[id] = $0 }
            parallel -= 1
            coordinator.recordHealth(self.health("0.1.21"), for: .init(workspaceId: id))
        }, fetchCatalog: { releases += 1; return self.catalog("0.1.21") }, readWorkspace: { reads[$0.id, default: 0] += 1 })
        let firstUpdate = Task { await queue.updateAll(workspaces) }
        try await eventually { gates.count == 3 }
        let repeatedUpdate = Task { await queue.updateAll(workspaces) }
        let repeatedCheck = Task { await queue.checkUpdates(workspaces) }
        await Task.yield()
        XCTAssertTrue(queue.busy)
        XCTAssertTrue(queue.updatingAll)
        XCTAssertFalse(queue.checking)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(reads.count, 5)
        XCTAssertTrue(reads.values.allSatisfy { $0 == 1 })
        let first = Array(gates.values); gates.removeAll()
        first.forEach { $0.resume() }
        try await eventually { gates.count == 2 }
        let second = Array(gates.values); gates.removeAll()
        second.forEach { $0.resume() }
        let results = await [firstUpdate.value, repeatedUpdate.value, repeatedCheck.value]
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertFalse(queue.busy)
        XCTAssertEqual(releases, 1)
        XCTAssertTrue(reads.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(peak, 3)
        XCTAssertEqual(calls.count, 5)
        XCTAssertTrue(calls.values.allSatisfy { $0 == 1 })
        XCTAssertTrue(queue.requested.isEmpty)
    }

    func testNewReleaseDiscoveredDuringAnInstallPreservesTheManualRequest() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        stores.defaults.set(false, forKey: StorageKey.automaticServiceUpdates)
        let workspace = workspace("new-release"), key = DaemonWorkKey(workspaceId: "new-release")
        coordinator.recordHealth(health(), for: key)
        var version = "0.1.21", calls = 0, releases = 0
        var gate: CheckedContinuation<Void, Never>?
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, update: { _, automatic, target in
            XCTAssertFalse(automatic)
            calls += 1
            let installing = try XCTUnwrap(target)
            if calls == 1 { await withCheckedContinuation { gate = $0 } }
            coordinator.recordHealth(self.health(installing), for: key)
        }, fetchCatalog: { releases += 1; return self.catalog(version) }, readWorkspace: { _ in })
        let first = Task { await queue.updateAll([workspace]) }
        try await eventually { gate != nil }
        version = "0.1.22"
        await queue.refreshRelease(force: true)
        let second = Task { await queue.updateAll([workspace]) }
        await Task.yield()
        XCTAssertEqual(calls, 1, "An in-flight install must finish before another starts")
        gate?.resume()
        let results = await [first.value, second.value]
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(releases, 2, "Joining the update must not repeat release discovery")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(coordinator.states[key]?.installedVersion, "0.1.22")
        XCTAssertTrue(queue.requested.isEmpty)
        XCTAssertFalse(coordinator.states[key]?.updateWaiting ?? true)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The update check or queue did not settle")
    }
}
