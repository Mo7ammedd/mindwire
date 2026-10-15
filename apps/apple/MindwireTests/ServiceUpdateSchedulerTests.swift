import XCTest
@testable import Mindwire

@MainActor
final class ServiceUpdateSchedulerTests: XCTestCase {
    private let workspace = Workspace(id: "service-update", name: "Workspace", runtime: .server(serverId: "server"), createdAt: "now")

    private func stores() throws -> Stores {
        let name = "MindwireTests.service-update.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Stores(defaults: defaults)
    }

    private func coordinator(_ stores: Stores, supported: Bool = true) -> DaemonWorkCoordinator {
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        coordinator.recordHealth(.init(ok: true, version: "1.0.0", workspaceMetadataVersion: 1,
            projectOperationsVersion: 1, serviceUpdateVersion: supported ? 1 : nil),
            for: .init(workspaceId: workspace.id), latest: "1.0.1")
        return coordinator
    }

    func testUpdatesAreOnByDefaultAndConcurrentReconciliationsShareOneJob() async throws {
        let stores = try stores(), coordinator = coordinator(stores)
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, update: { id, automatic, _ in
            XCTAssertEqual(id, self.workspace.id)
            XCTAssertTrue(automatic)
            calls += 1
            await withCheckedContinuation { gate = $0 }
        })
        XCTAssertTrue(queue.automaticUpdates)
        queue.reconcile([workspace]); queue.reconcile([workspace])
        try await eventually { gate != nil }
        queue.reconcile([workspace])
        XCTAssertEqual(calls, 1)
        gate?.resume()
        try await eventually { queue.active.isEmpty }
        queue.reconcile([workspace])
        XCTAssertEqual(calls, 1, "No repeat download on navigation or every foreground tick")
    }

    func testAutomaticSetupRespectsOptOutAndSharesOneJobAcrossReconciliations() async throws {
        for runtime in [AgentRuntime.cloud(workspaceId: "fresh"), .server(serverId: "server")] {
            let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
            let workspace = Workspace(id: "fresh", name: "Fresh workspace", runtime: runtime, createdAt: "now")
            let key = DaemonWorkKey(workspaceId: workspace.id)
            coordinator.recordWorkspaceStatus(.init(power: .running), for: key)
            coordinator.recordFailure(URLError(.cannotConnectToHost), for: key, revision: coordinator.probeRevision(key))
            var gate: CheckedContinuation<Void, Never>?
            var calls = 0
            let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, prepare: { id in
                XCTAssertEqual(id, workspace.id)
                calls += 1
                await withCheckedContinuation { gate = $0 }
            }, update: { _, _, _ in XCTFail("A first install must use the safe preparation path") })

            XCTAssertTrue(queue.automaticUpdates)
            stores.defaults.set(false, forKey: StorageKey.automaticServiceUpdates)
            queue.reconcile([workspace])
            XCTAssertTrue(queue.active.isEmpty)
            stores.defaults.set(true, forKey: StorageKey.automaticServiceUpdates)
            queue.reconcile([workspace]); queue.reconcile([workspace])
            try await eventually { gate != nil }
            queue.reconcile([workspace])
            XCTAssertEqual(calls, 1)
            stores.defaults.set(false, forKey: StorageKey.automaticServiceUpdates)
            gate?.resume()
            try await eventually { queue.active.isEmpty }
            queue.reconcile([workspace])
            XCTAssertEqual(calls, 1, "Turning the preference off must let an in-flight install finish")
        }
    }

    func testCloudSetupWaitsForConfirmedRunningPowerState() throws {
        let workspace = Workspace(id: "cloud", name: "Cloud", runtime: .cloud(workspaceId: "cloud"), createdAt: "now")
        for power in [nil, .unknown, .stopped, .starting, .stopping] as [WorkspacePower?] {
            let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
            let key = DaemonWorkKey(workspaceId: workspace.id)
            if let power { coordinator.recordWorkspaceStatus(.init(power: power), for: key) }
            coordinator.recordFailure(URLError(.cannotConnectToHost), for: key, revision: coordinator.probeRevision(key))
            let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, prepare: { _ in
                XCTFail("Automatic setup must not wake or guess the state of a workspace")
            }, update: { _, _, _ in XCTFail("No service to update") })
            queue.reconcile([workspace])
            XCTAssertTrue(queue.active.isEmpty)
        }
    }

    func testAutomaticSetupJoinsCreationWithoutStartingASecondPreparation() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let key = DaemonWorkKey(workspaceId: workspace.id)
        coordinator.recordFailure(URLError(.cannotConnectToHost), for: key, revision: 0)
        var gate: CheckedContinuation<Void, Never>?
        stores.preparation = PreparationQueue(stores: stores, canResolve: { _ in true }, prepareWorkspace: { _ in
            await withCheckedContinuation { gate = $0 }
            coordinator.recordHealth(.init(ok: true, version: "1.0.1", workspaceMetadataVersion: 1,
                projectOperationsVersion: 1, serviceUpdateVersion: 1), for: key, latest: "1.0.1")
        })
        stores.preparation.enqueue(workspaceId: workspace.id)
        try await eventually { gate != nil }
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, prepare: { _ in
            XCTFail("Creation already owns setup, including the time before its installer starts")
        }, update: { _, _, _ in XCTFail("Creation installs the current version") })
        queue.reconcile([workspace])
        XCTAssertTrue(queue.active.isEmpty)
        gate?.resume()
        try await eventually { stores.preparation.active.isEmpty }
        queue.reconcile([workspace])
        XCTAssertTrue(queue.active.isEmpty)
    }

    func testAutomaticSetupFailureBacksOffIndependentlyOfNavigation() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        coordinator.recordFailure(URLError(.cannotConnectToHost), for: .init(workspaceId: workspace.id), revision: 0)
        var date = Date(), calls = 0
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, now: { date }, prepare: { _ in
            calls += 1
            throw URLError(.notConnectedToInternet)
        })
        queue.reconcile([workspace])
        try await eventually { queue.active.isEmpty }
        date.addTimeInterval(60)
        queue.reconcile([workspace])
        XCTAssertEqual(calls, 1)
        date.addTimeInterval(241)
        queue.reconcile([workspace])
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(calls, 2)
    }

    func testManualUpdateDuringAutomaticSetupIsRetainedEvenAfterOptOut() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        coordinator.recordFailure(URLError(.cannotConnectToHost), for: .init(workspaceId: workspace.id), revision: 0)
        var gate: CheckedContinuation<Void, Never>?
        var updates = 0
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, prepare: { _ in
            await withCheckedContinuation { gate = $0 }
            coordinator.recordHealth(.init(ok: true, version: "1.0.0", workspaceMetadataVersion: 1,
                projectOperationsVersion: 1, serviceUpdateVersion: 1),
                for: .init(workspaceId: self.workspace.id), latest: "1.0.1")
        }, update: { _, automatic, _ in
            XCTAssertFalse(automatic)
            updates += 1
        })
        queue.reconcile([workspace])
        try await eventually { gate != nil }
        queue.enqueue(workspaceId: workspace.id)
        stores.defaults.set(false, forKey: StorageKey.automaticServiceUpdates)
        gate?.resume()
        try await eventually { queue.active.isEmpty }
        XCTAssertTrue(queue.requested.contains(workspace.id))
        queue.reconcile([workspace])
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(updates, 1)
        XCTAssertTrue(queue.requested.isEmpty)
    }

    func testManualRetryBypassesBusyCooldownAndRepeatedTapsJoinOneRequest() async throws {
        let stores = try stores(), coordinator = coordinator(stores)
        var calls = 0
        var gate: CheckedContinuation<Void, Never>?
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, update: { _, automatic, _ in
            XCTAssertFalse(automatic)
            calls += 1
            if calls == 1 { throw DaemonUpdateError.busy }
            await withCheckedContinuation { gate = $0 }
        })
        queue.enqueue(workspaceId: workspace.id)
        try await eventually { queue.active.isEmpty }
        let state = try XCTUnwrap(coordinator.states[.init(workspaceId: workspace.id)])
        XCTAssertTrue(state.updateWaiting)
        XCTAssertNil(state.error)
        XCTAssertTrue(queue.requested.contains(workspace.id))
        queue.reconcile([workspace])
        XCTAssertEqual(calls, 1, "Background reconciliation respects the retry delay")
        queue.enqueue(workspaceId: workspace.id)
        try await eventually { gate != nil }
        queue.enqueue(workspaceId: workspace.id)
        queue.enqueue(workspaceId: workspace.id)
        queue.reconcile([workspace])
        XCTAssertEqual(calls, 2, "Manual retry is immediate, and extra taps share its active request")
        gate?.resume()
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(state.updateWaiting)
        XCTAssertTrue(queue.requested.isEmpty)
    }

    func testManualRequestDuringAutomaticDownloadPromotesTheAcceptedUpdate() async throws {
        let stores = try stores(), coordinator = coordinator(stores)
        let key = DaemonWorkKey(workspaceId: workspace.id)
        var gate: CheckedContinuation<Void, Never>?
        var attempts: [Bool] = []
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, update: { _, automatic, _ in
            attempts.append(automatic)
            if automatic {
                await withCheckedContinuation { gate = $0 }
                throw DaemonUpdatePending(operation: .init(id: "accepted-update", version: "1.0.1", status: "waiting"))
            }
            XCTAssertEqual(coordinator.states[key]?.updateOperation?.id, "accepted-update")
            coordinator.recordHealth(.init(ok: true, version: "1.0.1", workspaceMetadataVersion: 1,
                projectOperationsVersion: 1, serviceUpdateVersion: 2), for: key)
        }, observeUpdate: { _ in
            XCTFail("Manual intent must promote the automatic request before observing it")
        })
        queue.reconcile([workspace])
        try await eventually { gate != nil }
        queue.enqueue(workspaceId: workspace.id)
        queue.enqueue(workspaceId: workspace.id)
        stores.defaults.set(false, forKey: StorageKey.automaticServiceUpdates)
        gate?.resume()
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(attempts, [true, false])
        XCTAssertTrue(queue.requested.isEmpty)
        XCTAssertFalse(coordinator.states[key]?.updateWaiting ?? true)
        XCTAssertEqual(coordinator.states[key]?.updateOperation?.status, "complete")
    }

    func testOfflineMissingLegacyAndBusyWorkspaceAreNotAutomaticallyInstalledOrWoken() async throws {
        for reason in ["offline", "missing", "legacy", "setup", "stopped", "upToDate"] {
            let stores = try stores(), coordinator = coordinator(stores, supported: reason != "legacy")
            let state = try XCTUnwrap(coordinator.states[.init(workspaceId: workspace.id)])
            if reason == "offline" { state.reachable = false }
            if reason == "missing" { state.installedVersion = nil }
            if reason == "setup" { state.running = true }
            if reason == "stopped" { state.powerAction = .start }
            if reason == "upToDate" { state.latestVersion = state.installedVersion }
            let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, update: { _, _, _ in
                XCTFail("Should not update: \(reason)")
            })
            queue.reconcile([workspace])
            XCTAssertTrue(queue.active.isEmpty)
        }
    }

    func testOptOutKeepsManualUpdateAvailableAndRequestsSurviveRelaunch() async throws {
        let stores = try stores(), coordinator = coordinator(stores)
        stores.defaults.set(false, forKey: StorageKey.automaticServiceUpdates)
        let first = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in false })
        first.reconcile([workspace])
        XCTAssertTrue(first.active.isEmpty)
        first.enqueue(workspaceId: workspace.id)
        var calls = 0
        let second = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, update: { _, automatic, _ in
            XCTAssertFalse(automatic); calls += 1
        })
        XCTAssertFalse(second.automaticUpdates)
        second.reconcile([workspace])
        try await eventually { second.active.isEmpty }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(second.requested.isEmpty)
    }

    func testObservedRemoteSetupDoesNotKeepUpdatesWaitingAfterItFinishes() async throws {
        let stores = try stores(), coordinator = coordinator(stores)
        let key = DaemonWorkKey(workspaceId: workspace.id, agentType: "codex")
        coordinator.recordPreparation(.init(ok: false, running: true, steps: []), for: key, revision: 0)
        var calls = 0
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, update: { _, automatic, _ in
            XCTAssertTrue(automatic)
            // The remote update path obtains current daemon activity and a final lease.
            calls += 1
        })
        queue.reconcile([workspace])
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(calls, 1, "Cached CLI status must not overrule the service's fresh idle check")
    }

    func testFailedAutomaticUpdateBacksOffButExplicitRetryBypassesDelay() async throws {
        let stores = try stores(), coordinator = coordinator(stores)
        var date = Date(), calls = 0
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, now: { date }, update: { _, _, _ in
            calls += 1; throw URLError(.cannotConnectToHost)
        })
        queue.reconcile([workspace])
        try await eventually { queue.active.isEmpty }
        date.addTimeInterval(60)
        queue.reconcile([workspace]); XCTAssertEqual(calls, 1)
        queue.enqueue(workspaceId: workspace.id)
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(queue.requested.isEmpty)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Service update did not finish")
    }
}
