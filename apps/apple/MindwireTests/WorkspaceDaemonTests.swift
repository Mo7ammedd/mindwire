import XCTest
import struct OblienKit.OblienError
@testable import Mindwire

@MainActor
final class WorkspaceDaemonTests: XCTestCase {
    private let workspace = Workspace(id: "workspace-daemon-test", name: "Workspace",
        runtime: .server(serverId: "test-server"), createdAt: "2026-09-16T00:00:00Z")

    private func defaults() throws -> UserDefaults {
        let name = "MindwireTests.workspace-daemon.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func client(_ channel: WorkspaceDaemonFixture, coordinator: DaemonWorkCoordinator) throws -> WorkspaceRegistryClient {
        let stores = Stores(defaults: try defaults())
        let catalog = DaemonCatalog(version: "0.1.13", agents: [AgentDescriptor(id: .codex, name: "Codex", tagline: "Coding")])
        return WorkspaceRegistryClient(workspace: workspace, stores: stores,
            http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator,
            releases: ReleaseCatalog(defaults: try defaults(), fetch: { catalog }), installer: channel)
    }

    func testOldDaemonExposesItsVersionAndCompatibilityWithoutStartingAProject() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let channel = WorkspaceDaemonFixture(compatible: false)
        let client = try client(channel, coordinator: coordinator)
        do { try await client.prepare(allowInstall: false); XCTFail("Expected an update requirement") }
        catch { XCTAssertEqual(error.localizedDescription, WorkspaceRegistryError.updateRequired.localizedDescription) }
        let state = try XCTUnwrap(coordinator.states[.init(workspaceId: workspace.id)])
        XCTAssertEqual(state.installedVersion, "0.1.12")
        XCTAssertEqual(state.reachable, true, "An old daemon is reachable, but incompatible")
        XCTAssertFalse(state.canCreateProjects)
        do {
            _ = try await client.startProject(.init(id: "new", source: "folder", name: "New", path: "/work/new"))
            XCTFail("Do not POST to a daemon missing the capability")
        } catch {}
        let calls = await channel.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("POST") })
    }

    func testPendingWorkspacePreparationNeverUpgradesAnExistingService() async throws {
        for offline in [false, true] {
            let coordinator = DaemonWorkCoordinator(defaults: try defaults())
            let channel = WorkspaceDaemonFixture(compatible: true, version: "0.1.12")
            if offline { await channel.disconnect() }
            let client = try client(channel, coordinator: coordinator)
            try await client.prepare(allowInstall: true)
            let installs = await channel.installs
            XCTAssertEqual(installs, 0, "Resuming first-run preparation is not an update action")
            XCTAssertEqual(coordinator.states[.init(workspaceId: workspace.id)]?.installedVersion, "0.1.12")
        }
    }

    func testReadOnlyProjectPreparationRecoversStoppedListenerWithoutInstalling() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let channel = WorkspaceDaemonFixture(compatible: true, version: "0.1.12")
        await channel.stopService()
        let first = try client(channel, coordinator: coordinator)
        let second = try client(channel, coordinator: coordinator)
        async let a: Void = first.prepare(allowInstall: false)
        async let b: Void = second.prepare(allowInstall: false)
        _ = try await (a, b)
        let starts = await channel.starts, installs = await channel.installs
        XCTAssertEqual(starts, 1, "Concurrent project screens share recovery")
        XCTAssertEqual(installs, 0, "Source control recovery cannot download or replace a service")
        XCTAssertTrue(first.supportsGitOperations == second.supportsGitOperations)
        XCTAssertEqual(coordinator.states[.init(workspaceId: workspace.id)]?.installedVersion, "0.1.12")
    }

    func testReadOnlyRecoveryCannotInstallAnAbsentBinary() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let channel = WorkspaceDaemonFixture(compatible: false, installed: false)
        await channel.stopService()
        let client = try client(channel, coordinator: coordinator)
        do {
            try await client.prepare(allowInstall: false)
            XCTFail("A missing installation still requires setup")
        } catch { XCTAssertTrue(error is DaemonBootstrapError) }
        let installs = await channel.installs
        XCTAssertEqual(installs, 0)
    }

    func testCancelledPreparationNeverStartsOrInstallsAService() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let channel = WorkspaceDaemonFixture(compatible: true)
        await channel.cancelHealth()
        let client = try client(channel, coordinator: coordinator)
        do { try await client.prepare(allowInstall: true); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error.isRequestCancellation) }
        let starts = await channel.starts, installs = await channel.installs
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(installs, 0)
    }

    func testNotificationCapabilityFollowsVerifiedHealthAndIsSharedWithOtherClients() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let channel = WorkspaceDaemonFixture(compatible: true)
        let first = try client(channel, coordinator: coordinator)
        try await first.prepare(allowInstall: false)
        XCTAssertFalse(first.supportsNotificationPreferences)
        await channel.setNotificationPreferencesVersion(1)
        first.invalidateChecks()
        try await first.prepare(allowInstall: false)
        XCTAssertTrue(first.supportsNotificationPreferences)
        let second = try client(channel, coordinator: coordinator)
        let before = await channel.calls
        try await second.prepare(allowInstall: false)
        XCTAssertTrue(second.supportsNotificationPreferences)
        let after = await channel.calls
        XCTAssertEqual(after, before, "A second client should reuse the verified health response")
        await channel.disconnect()
        first.invalidateChecks()
        do { try await first.prepare(allowInstall: false); XCTFail("Expected disconnect") } catch {}
        XCTAssertFalse(first.supportsNotificationPreferences, "Failed preparation cannot reuse a stale capability")
        let installs = await channel.installs
        XCTAssertEqual(installs, 0)
    }

    func testConcurrentWorkspaceUpdatesShareJobAndRecheckActualInstalledVersion() async throws {
        let defaults = try defaults()
        let coordinator = DaemonWorkCoordinator(defaults: defaults)
        let channel = WorkspaceDaemonFixture(compatible: false)
        await channel.holdInstallation()
        let a = try client(channel, coordinator: coordinator), b = try client(channel, coordinator: coordinator)
        let first = Task { try await a.updateDaemon() }
        for _ in 0..<200 {
            if await channel.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let key = DaemonWorkKey(workspaceId: workspace.id)
        XCTAssertEqual(coordinator.states[key]?.running, true)
        let second = Task { try await b.updateDaemon() }
        try await Task.sleep(for: .milliseconds(20))
        await channel.finishInstallation()
        try await first.value
        try await second.value
        let installs = await channel.installs
        XCTAssertEqual(installs, 1)
        let calls = await channel.calls
        XCTAssertEqual(calls.filter { $0 == "GET /healthz" }.count, 2,
            "Concurrent callers share the preflight and final version acknowledgement")
        XCTAssertEqual(coordinator.states[key]?.installedVersion, "0.1.13")
        XCTAssertEqual(coordinator.states[key]?.canCreateProjects, true)
        XCTAssertEqual(coordinator.states[key]?.running, false)
        XCTAssertTrue(a.supportsProjectOperations)
        XCTAssertTrue(b.supportsProjectOperations)

        let restarted = DaemonWorkCoordinator(defaults: defaults)
        XCTAssertEqual(restarted.states[key]?.installedVersion, "0.1.13")
        XCTAssertEqual(restarted.states[key]?.latestVersion, "0.1.13")
        XCTAssertNil(restarted.states[key]?.reachable, "Cached status must be checked after relaunch")
        XCTAssertEqual(restarted.states[key]?.canCreateProjects, false)
        XCTAssertEqual(restarted.states[key]?.running, false)
        let reopened = try client(channel, coordinator: restarted)
        try await reopened.prepare(allowInstall: false)
        XCTAssertEqual(restarted.states[key]?.canCreateProjects, true)
    }

    func testProjectChatAndCLIOperationsEachPreventAutomaticDaemonReplacement() async throws {
        for busy in ["project", "claude-chat", "codex-setup"] {
            let coordinator = DaemonWorkCoordinator(defaults: try defaults())
            let channel = WorkspaceDaemonFixture(compatible: true)
            await channel.setServiceUpdateVersion(1)
            await channel.setBusy(busy)
            let client = try client(channel, coordinator: coordinator)
            do { try await client.updateDaemonWhenIdle(); XCTFail("Must not automatically replace daemon during \(busy)") }
            catch { XCTAssertEqual(error.localizedDescription, t("workspace.daemon.busy")) }
            let installs = await channel.installs
            XCTAssertEqual(installs, 0)
            XCTAssertEqual(coordinator.states[.init(workspaceId: workspace.id)]?.installedVersion, "0.1.12")
        }
    }

    func testManualServiceUpdatePassesRestartIntentEvenWhenWorkIsActive() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let channel = WorkspaceDaemonFixture(compatible: true)
        await channel.setServiceUpdateVersion(2)
        await channel.setBusy("claude-chat")
        let client = try client(channel, coordinator: coordinator)
        try await client.updateDaemon()
        let force = await channel.forcedUpdate
        let installs = await channel.installs
        XCTAssertTrue(force)
        XCTAssertEqual(installs, 1)
        XCTAssertFalse(coordinator.states[.init(workspaceId: workspace.id)]?.updateAvailable ?? true)
    }

    func testBatchTargetAvoidsPerWorkspaceReleaseChecksAndIdleProbeIsShared() async throws {
        for automatic in [false, true] {
            let stores = Stores(defaults: try defaults())
            let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
            let channel = WorkspaceDaemonFixture(compatible: true)
            await channel.setServiceUpdateVersion(1)
            await channel.holdInstallation()
            let releases = ReleaseCatalog(defaults: stores.defaults, fetch: {
                XCTFail("The batch already verified the target release")
                throw URLError(.badServerResponse)
            })
            let a = WorkspaceRegistryClient(workspace: workspace, stores: stores,
                http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator,
                releases: releases, installer: channel)
            let b = WorkspaceRegistryClient(workspace: workspace, stores: stores,
                http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator,
                releases: releases, installer: channel)
            let first = Task { try await a.updateDaemon(automatic: automatic, target: "0.1.22") }
            try await eventually { await channel.waiting }
            let duplicate = Task { try await b.updateDaemon(automatic: automatic, target: "0.1.22") }
            try await Task.sleep(for: .milliseconds(20))
            await channel.finishInstallation()
            try await first.value
            try await duplicate.value
            let calls = await channel.calls, installs = await channel.installs
            XCTAssertEqual(installs, 1)
            XCTAssertEqual(calls.filter { $0 == "GET /healthz" }.count, 2)
            XCTAssertEqual(calls.filter { $0 == "GET /service/update" }.count, automatic ? 1 : 0)
        }
    }

    func testMetadataAfterUpdateReusesVerifiedServiceHealth() async throws {
        let stores = Stores(defaults: try defaults())
        let workspace = Workspace(id: UUID().uuidString, name: "Update", runtime: .server(serverId: "test"), createdAt: isoNow())
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let coordinator = DaemonWorkCoordinator.shared
        defer { coordinator.forget(workspaceId: workspace.id) }
        let channel = WorkspaceDaemonFixture(compatible: true)
        await channel.setServiceUpdateVersion(1)
        var releases = 0
        let source = ReleaseCatalog(defaults: stores.defaults, fetch: {
            releases += 1
            return DaemonCatalog(version: "0.1.22", agents: [.init(id: .codex, name: "Codex", tagline: "Coding")])
        })
        _ = try await source.load(maxAge: 0, allowStale: false)
        let client = WorkspaceRegistryClient(workspace: workspace, stores: stores,
            http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator,
            releases: source, installer: channel)
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in client }, resolveWorkspace: { _ in workspace })
        try await data.updateDaemon(workspaceId: workspace.id, target: "0.1.22")
        let calls = await channel.calls
        XCTAssertEqual(calls.filter { $0 == "GET /healthz" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "GET /service/update" }.count, 0)
        XCTAssertNotNil(data.identity(workspaceId: workspace.id), "Updated capabilities still reconcile workspace metadata")
        XCTAssertNotNil(coordinator.freshHealth(for: key))
        XCTAssertNil(data.errors[workspace.id])
        XCTAssertEqual(releases, 1)
    }

    func testInstallerSuccessAloneCannotMarkAnOldRunningVersionUpdated() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        coordinator.recordLatestRelease("0.1.12")
        let channel = WorkspaceDaemonFixture(compatible: true)
        await channel.ignoreInstallation()
        let client = try client(channel, coordinator: coordinator)
        do { try await client.updateDaemon(); XCTFail("The running version must be verified") }
        catch { XCTAssertEqual(error.localizedDescription, t("workspace.daemon.verifyFailed")) }
        let state = try XCTUnwrap(coordinator.states[.init(workspaceId: workspace.id)])
        XCTAssertEqual(state.installedVersion, "0.1.12")
        XCTAssertTrue(state.updateAvailable)
        XCTAssertNotNil(state.error)
    }

    func testWorkspaceUpdateQueueActuallyUpgradesAnExistingHealthyService() async throws {
        let stores = Stores(defaults: try defaults())
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let channel = WorkspaceDaemonFixture(compatible: true)
        let client = try client(channel, coordinator: coordinator)
        try await client.prepare(allowInstall: false)
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true }, update: { _, automatic, _ in
            XCTAssertFalse(automatic)
            try await client.updateDaemon()
        })
        queue.enqueue(workspaceId: workspace.id)
        queue.enqueue(workspaceId: workspace.id)
        try await eventually { queue.active.isEmpty }
        let installs = await channel.installs
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(coordinator.states[.init(workspaceId: workspace.id)]?.installedVersion, "0.1.13")
        XCTAssertFalse(coordinator.states[.init(workspaceId: workspace.id)]?.updateAvailable == true)
    }

    func testUpdateIntentSurvivesJoiningHealthyPreparation() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let channel = WorkspaceDaemonFixture(compatible: true)
        let client = try client(channel, coordinator: coordinator)
        var gate: CheckedContinuation<Void, Never>?
        let preparation = Task { try await coordinator.perform(.init(workspaceId: workspace.id)) { _ in
            await withCheckedContinuation { gate = $0 }
        } }
        try await eventually { gate != nil }
        let update = Task { try await client.updateDaemon() }
        await Task.yield()
        gate?.resume()
        try await preparation.value
        try await update.value
        let installs = await channel.installs
        XCTAssertEqual(installs, 1, "Joining preparation must not consume the Update action")
    }

    func testAutomaticUpdateRequiresServerLeaseAndDefersActiveWork() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let channel = WorkspaceDaemonFixture(compatible: true)
        let client = try client(channel, coordinator: coordinator)
        do { try await client.updateDaemonWhenIdle(); XCTFail("Legacy services require an explicit upgrade") }
        catch { XCTAssertEqual(error as? DaemonUpdateError, .unsupported) }
        await channel.setServiceUpdateVersion(1)
        await channel.setBusy("chat")
        do { try await client.updateDaemonWhenIdle(); XCTFail("An active chat must prevent replacement") }
        catch { XCTAssertEqual(error as? DaemonUpdateError, .busy) }
        let before = await channel.installs
        XCTAssertEqual(before, 0)
        await channel.setBusy("")
        try await client.updateDaemonWhenIdle()
        let guarded = await channel.requiredUpdateLease
        XCTAssertTrue(guarded)
        XCTAssertEqual(coordinator.states[.init(workspaceId: workspace.id)]?.installedVersion, "0.1.13")
    }

    func testConnectionFailurePreservesLastVersionAndForgettingWorkspaceClearsIt() async throws {
        let savedDefaults = try defaults()
        let coordinator = DaemonWorkCoordinator(defaults: savedDefaults)
        let channel = WorkspaceDaemonFixture(compatible: true)
        let client = try client(channel, coordinator: coordinator)
        try await client.prepare(allowInstall: false)
        await channel.disconnect()
        client.invalidateChecks() // manual Retry/Refresh bypasses the recent successful probe
        do { try await client.prepare(allowInstall: false); XCTFail("Expected a connection failure") } catch {}
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let state = try XCTUnwrap(coordinator.states[key])
        XCTAssertEqual(state.installedVersion, "0.1.12")
        XCTAssertEqual(state.reachable, false)
        XCTAssertFalse(state.canCreateProjects)
        XCTAssertFalse(client.supportsProjectOperations)

        let restarted = DaemonWorkCoordinator(defaults: savedDefaults)
        XCTAssertEqual(restarted.states[key]?.installedVersion, "0.1.12")
        XCTAssertNil(restarted.states[key]?.reachable)
        coordinator.forget(workspaceId: workspace.id)
        XCTAssertNil(DaemonWorkCoordinator(defaults: savedDefaults).states[key])
    }

    func testProbeStartedBeforeUpdateCannotRollBackVersionOrCapabilities() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let staleRevision = coordinator.probeRevision(key)
        try await coordinator.perform(key) { _ in
            coordinator.recordHealth(.init(ok: true, version: "0.1.13", workspaceMetadataVersion: 1, projectOperationsVersion: 1), for: key)
        }
        coordinator.recordHealth(.init(ok: true, version: "0.1.12"), for: key, revision: staleRevision)
        XCTAssertEqual(coordinator.states[key]?.installedVersion, "0.1.13")
        XCTAssertEqual(coordinator.states[key]?.canCreateProjects, true)
    }

    func testWorkspaceHealthIsSharedWithoutRenewingExpiryAndExplicitChecksBypassIt() async throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let channel = WorkspaceDaemonFixture(compatible: true)
        let first = try client(channel, coordinator: coordinator), second = try client(channel, coordinator: coordinator)
        try await first.prepare(allowInstall: false)
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let checkedAt = try XCTUnwrap(coordinator.states[key]?.checkedAt)
        try await second.prepare(allowInstall: false)
        let calls = await channel.calls
        XCTAssertEqual(calls.filter { $0.contains("/healthz") }.count, 1)
        XCTAssertEqual(coordinator.states[key]?.checkedAt, checkedAt, "Reading a cache cannot keep it fresh forever")
        XCTAssertNil(coordinator.freshHealth(for: key, at: checkedAt.addingTimeInterval(61)))

        second.invalidateChecks()
        XCTAssertNil(coordinator.freshHealth(for: key))
        try await second.prepare(allowInstall: false)
        let refreshed = await channel.calls
        XCTAssertEqual(refreshed.filter { $0.contains("/healthz") }.count, 2)
        XCTAssertTrue(second.supportsProjectOperations)
    }

    func testRepeatedOfflineObservationsDoNotContinuouslyInvalidateTheRetryCooldown() throws {
        let coordinator = DaemonWorkCoordinator(defaults: try defaults())
        let key = DaemonWorkKey(workspaceId: workspace.id)
        coordinator.recordHealth(.init(ok: true, version: "0.1.13"), for: key)
        let healthyRevision = coordinator.probeRevision(key)
        coordinator.recordHealth(.init(ok: false), for: key)
        let offlineRevision = coordinator.probeRevision(key)
        XCTAssertNotEqual(healthyRevision, offlineRevision, "A new connection failure invalidates healthy caches")
        coordinator.recordHealth(.init(ok: false), for: key)
        XCTAssertEqual(coordinator.probeRevision(key), offlineRevision, "Repeated observations of the same outage must respect backoff")
        XCTAssertNil(coordinator.freshHealth(for: key))
        XCTAssertEqual(coordinator.states[key]?.installedVersion, "0.1.13")
    }

    func testStoppedVMIsDiagnosedBeforeAnyRuntimeProxyRequestAndStartVerifiesService() async throws {
        let stores = Stores(defaults: try defaults())
        let coordinator = DaemonWorkCoordinator.shared
        let key = DaemonWorkKey(workspaceId: workspace.id)
        coordinator.forget(workspaceId: workspace.id)
        defer { coordinator.forget(workspaceId: workspace.id) }
        let backend = WorkspaceControlFixture()
        backend.currentPower = .stopped
        backend.afterPower = .starting
        let channel = WorkspaceDaemonFixture(compatible: true, version: "0.1.13")
        let client = WorkspaceRegistryClient(workspace: workspace, stores: stores,
            http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator, installer: channel, backend: backend)
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in client }, resolveWorkspace: { _ in self.workspace })
        await data.refresh(workspace)
        XCTAssertEqual(coordinator.states[key]?.workspaceStatus?.power, .stopped)
        XCTAssertNil(data.errors[workspace.id])
        let stoppedCalls = await channel.calls
        XCTAssertTrue(stoppedCalls.isEmpty, "Stopped VMs need Start, not a proxy/credential request or installation")
        XCTAssertEqual(coordinator.states[key]?.workspaceStatusTitle, t("workspace.power.stopped"))
        XCTAssertEqual(coordinator.states[key]?.canCreateProjects, false)

        var serviceChecks = 0
        await channel.failNextHealthChecks(1)
        let model = WorkspaceModel(backend: backend, onChange: { data.invalidateChecks(self.workspace.id) },
            workspaceId: workspace.id, coordinator: coordinator, wait: { backend.currentPower = .running }, verifyService: {
                serviceChecks += 1
                await data.refresh(self.workspace)
                return coordinator.states[key]?.reachable == true
            })
        await model.power(.start)
        XCTAssertEqual(backend.powerCalls, [.start])
        XCTAssertEqual(model.status?.power, .running)
        XCTAssertEqual(serviceChecks, 1, "Preparation handles a warming proxy without another UI retry")
        XCTAssertNil(data.errors[workspace.id])
        XCTAssertNil(coordinator.states[key]?.connectionError)
        XCTAssertNil(coordinator.states[key]?.powerAction)
        XCTAssertEqual(coordinator.states[key]?.canCreateProjects, true)
        let installs = await channel.installs
        XCTAssertEqual(installs, 0)
    }

    func testMetadataFailureInvalidatesCachedRunningVMAndDiagnosesExternalStopImmediately() async throws {
        let stores = Stores(defaults: try defaults())
        let coordinator = DaemonWorkCoordinator.shared
        let key = DaemonWorkKey(workspaceId: workspace.id)
        coordinator.forget(workspaceId: workspace.id)
        defer { coordinator.forget(workspaceId: workspace.id) }
        let backend = WorkspaceControlFixture()
        let channel = WorkspaceDaemonFixture(compatible: true)
        let client = WorkspaceRegistryClient(workspace: workspace, stores: stores,
            http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator, installer: channel, backend: backend)
        var now = Date()
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in client }, now: { now })
        await data.refresh(workspace)
        XCTAssertEqual(coordinator.states[key]?.workspaceStatus?.power, .running)
        backend.currentPower = .stopped
        await channel.disconnect()
        // Expire metadata's check while management/health are still cached; failure is from /workspace.
        now.addTimeInterval(61)
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(coordinator.states[key]?.workspaceStatus?.power, .stopped)
        XCTAssertNil(data.errors[workspace.id])
        XCTAssertEqual(coordinator.states[key]?.canCreateProjects, false)
        let checked = backend.statusCalls
        await data.refreshIfNeeded(workspace)
        XCTAssertEqual(backend.statusCalls, checked, "Known stopped state should not cause a retry storm")
    }

    func testVMStartRecoversInstalledServiceWithoutDownloadingAnUpdate() async throws {
        let stores = Stores(defaults: try defaults())
        let coordinator = DaemonWorkCoordinator.shared
        let key = DaemonWorkKey(workspaceId: workspace.id)
        coordinator.forget(workspaceId: workspace.id)
        defer { coordinator.forget(workspaceId: workspace.id) }
        let backend = WorkspaceControlFixture()
        let channel = WorkspaceDaemonFixture(compatible: true, version: "0.1.13")
        let client = WorkspaceRegistryClient(workspace: workspace, stores: stores,
            http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator, installer: channel, backend: backend)
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in client }, resolveWorkspace: { _ in self.workspace })
        await data.refresh(workspace)
        let model = WorkspaceModel(backend: backend, onChange: { data.invalidateChecks(self.workspace.id) },
            workspaceId: workspace.id, coordinator: coordinator, wait: {}, verifyService: {
                await data.refresh(self.workspace)
                return coordinator.states[key]?.reachable == true
            }, startService: { try? await data.startDaemon(workspaceId: self.workspace.id) })
        await model.power(.stop)
        await channel.disconnect() // the VM reboot lost its old daemon process
        await model.power(.start)
        XCTAssertEqual(coordinator.states[key]?.canCreateProjects, true)
        XCTAssertNil(coordinator.states[key]?.connectionError)
        XCTAssertNil(coordinator.states[key]?.error)
        let starts = await channel.starts, installs = await channel.installs
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(installs, 0, "Starting an existing service never upgrades or reinstalls it")
        try await data.startDaemon(workspaceId: workspace.id)
        let repeatedStarts = await channel.starts
        XCTAssertEqual(repeatedStarts, 1, "A healthy service must be reused")
    }

    func testAutomaticSetupConfirmsMissingBinaryAndKeepsExistingVersion() async throws {
        for installed in [false, true] {
            let stores = Stores(defaults: try defaults())
            let adapter = WorkspaceAdoptionFixture(workspace: workspace, present: true)
            let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
            let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
            let channel = WorkspaceDaemonFixture(compatible: true, installed: installed)
            await channel.disconnect()
            configurePreparation(stores, repository: repository, channel: channel, coordinator: coordinator)
            await stores.workspaceData.refresh(workspace)
            let key = DaemonWorkKey(workspaceId: workspace.id)
            XCTAssertEqual(coordinator.states[key]?.reachable, false)
            XCTAssertNil(coordinator.states[key]?.installedVersion, "A new client has not verified any installed version")

            let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { repository.get($0) != nil })
            queue.reconcile([workspace])
            try await eventually { queue.active.isEmpty }
            let installs = await channel.installs
            XCTAssertEqual(installs, installed ? 0 : 1, "Only a confirmed missing binary allows installation")
            XCTAssertEqual(coordinator.states[key]?.installedVersion, installed ? "0.1.12" : "0.1.13")
            XCTAssertEqual(coordinator.states[key]?.canCreateProjects, true)
            XCTAssertNil(stores.workspaceData.errors[workspace.id])
        }
    }

    func testNewCloudAndServerWorkspacesSetUpServiceEvenWithAutomaticUpdatesOff() async throws {
        for runtime in [AgentRuntime.cloud(workspaceId: "new-workspace"), .server(serverId: "test-server")] {
            let stores = Stores(defaults: try defaults())
            stores.defaults.set(false, forKey: StorageKey.automaticServiceUpdates)
            let created = Workspace(id: "new-workspace", name: "New workspace", runtime: runtime, createdAt: workspace.createdAt)
            let adapter = WorkspaceAdoptionFixture(workspace: created)
            let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
            let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
            let channel = WorkspaceDaemonFixture(compatible: false, installed: false)
            await channel.holdInstallation()
            configurePreparation(stores, repository: repository, channel: channel, coordinator: coordinator)

            let adopted = await repository.adopt(name: created.name, runtime: runtime, spec: nil)
            XCTAssertEqual(adopted?.id, created.id)
            XCTAssertTrue(stores.preparation.pendingWorkspaceIDs.contains(created.id))
            let key = DaemonWorkKey(workspaceId: created.id)
            try await eventually { await channel.waiting }
            XCTAssertEqual(coordinator.states[key]?.activity, .installingDaemon)
            XCTAssertEqual(coordinator.states[key]?.running, true)
            XCTAssertEqual(coordinator.states[key]?.canCreateProjects, false)

            // Reopening the page, repeated creation callbacks, and foreground resume join setup.
            stores.preparation.enqueue(workspaceId: created.id)
            stores.preparation.resume()
            await channel.finishInstallation()
            try await eventually { stores.preparation.active.isEmpty }
            let installs = await channel.installs
            XCTAssertEqual(installs, 1)
            XCTAssertTrue(stores.preparation.pendingWorkspaceIDs.isEmpty)
            XCTAssertEqual(coordinator.states[key]?.installedVersion, "0.1.13")
            XCTAssertEqual(coordinator.states[key]?.canCreateProjects, true)
            XCTAssertNil(stores.workspaceData.errors[created.id])
        }
    }

    func testRelaunchVerifiesCompletedServiceSetupWithoutInstallingAgain() async throws {
        let stores = Stores(defaults: try defaults())
        let first = PreparationQueue(stores: stores, canResolve: { _ in false }, prepareWorkspace: { _ in
            XCTFail("Do not connect before workspace inventory is available")
        })
        first.enqueue(workspaceId: workspace.id)
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let channel = WorkspaceDaemonFixture(compatible: true, version: "0.1.13")
        let client = try client(channel, coordinator: coordinator)
        let resumed = PreparationQueue(stores: stores, canResolve: { _ in true }, prepareWorkspace: { _ in
            try await client.updateDaemon()
        })
        XCTAssertEqual(resumed.pendingWorkspaceIDs, [workspace.id])
        XCTAssertTrue(resumed.active.isEmpty, "Persisted intent is not installed/running state")
        resumed.resume()
        try await eventually { resumed.active.isEmpty }
        let installs = await channel.installs
        XCTAssertEqual(installs, 0)
        XCTAssertTrue(resumed.pendingWorkspaceIDs.isEmpty)
        XCTAssertTrue(PreparationQueue(stores: stores).pendingWorkspaceIDs.isEmpty)
        XCTAssertEqual(coordinator.states[.init(workspaceId: workspace.id)]?.canCreateProjects, true)
    }

    func testFailedWorkspaceSetupWaitsForExplicitRetryAcrossForegroundAndRelaunch() async throws {
        let stores = Stores(defaults: try defaults())
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let channel = WorkspaceDaemonFixture(compatible: false, installed: false)
        await channel.failInstallation(true)
        let client = try client(channel, coordinator: coordinator)
        let queue = PreparationQueue(stores: stores, canResolve: { _ in true }, prepareWorkspace: { _ in
            try await client.updateDaemon()
        })
        queue.enqueue(workspaceId: workspace.id)
        try await eventually { queue.active.isEmpty }
        XCTAssertTrue(queue.pendingWorkspaceIDs.isEmpty)
        let key = DaemonWorkKey(workspaceId: workspace.id)
        XCTAssertNotNil(coordinator.states[key]?.error)
        XCTAssertFalse(coordinator.states[key]?.canCreateProjects == true)

        await channel.failInstallation(false)
        queue.resume()
        let relaunched = PreparationQueue(stores: stores, canResolve: { _ in true }, prepareWorkspace: { _ in
            XCTFail("Opening the app must not retry a completed failure")
        })
        relaunched.resume()
        XCTAssertTrue(relaunched.pendingWorkspaceIDs.isEmpty)
        let beforeRetry = await channel.installs
        XCTAssertEqual(beforeRetry, 1)
        queue.enqueue(workspaceId: workspace.id)
        try await eventually { queue.active.isEmpty }
        let installs = await channel.installs
        XCTAssertEqual(installs, 2)
        XCTAssertTrue(queue.pendingWorkspaceIDs.isEmpty)
        XCTAssertNil(coordinator.states[key]?.error)
        XCTAssertEqual(coordinator.states[key]?.canCreateProjects, true)
    }

    func testInventoryRefreshNeverInstallsServiceOnAnExistingWorkspace() async throws {
        let stores = Stores(defaults: try defaults())
        let adapter = WorkspaceAdoptionFixture(workspace: workspace, present: true)
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        let channel = WorkspaceDaemonFixture(compatible: false, installed: false)
        configurePreparation(stores, repository: repository, channel: channel,
                             coordinator: DaemonWorkCoordinator(defaults: stores.defaults))
        await repository.refresh()
        await stores.workspaceData.refresh(workspace)
        XCTAssertTrue(stores.preparation.pendingWorkspaceIDs.isEmpty)
        let installs = await channel.installs
        XCTAssertEqual(installs, 0)
    }

    func testPendingWorkspaceWithoutProjectsIsForgottenOnlyAfterConfirmedDeletion() async throws {
        let stores = Stores(defaults: try defaults())
        let adapter = WorkspaceAdoptionFixture(workspace: workspace)
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        stores.preparation = PreparationQueue(stores: stores, canResolve: { _ in false })
        stores.preparation.enqueue(workspaceId: workspace.id)
        await repository.refresh()
        XCTAssertEqual(stores.preparation.pendingWorkspaceIDs, [workspace.id])
        adapter.deleted = true
        await repository.refresh()
        XCTAssertTrue(stores.preparation.pendingWorkspaceIDs.isEmpty)
        XCTAssertTrue(PreparationQueue(stores: stores).pendingWorkspaceIDs.isEmpty)
    }

    func testStartingWorkspaceRetriesTemporaryFailureThenInstallsOnce() async throws {
        let stores = Stores(defaults: try defaults())
        let coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let channel = WorkspaceDaemonFixture(compatible: false, installed: false)
        let client = try client(channel, coordinator: coordinator)
        var attempts = 0
        var retry: CheckedContinuation<Void, Never>?
        defer { retry?.resume() }
        let queue = PreparationQueue(stores: stores, canResolve: { _ in true }, prepareWorkspace: { _ in
            attempts += 1
            if attempts == 1 {
                throw OblienError(kind: .server, status: 503, code: "workspace_starting", message: "Starting", details: nil)
            }
            try await client.updateDaemon()
        }, waitBeforeRetry: { _ in await withCheckedContinuation { retry = $0 } })
        queue.enqueue(workspaceId: workspace.id)
        try await eventually { retry != nil }
        XCTAssertEqual(queue.pendingWorkspaceIDs, [workspace.id])
        queue.enqueue(workspaceId: workspace.id)
        queue.resume()
        XCTAssertEqual(attempts, 1, "Navigation and repeated taps cannot bypass a pending retry")
        retry?.resume(); retry = nil
        try await eventually { queue.active.isEmpty }
        let installs = await channel.installs
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(queue.pendingWorkspaceIDs.isEmpty)
        XCTAssertEqual(coordinator.states[.init(workspaceId: workspace.id)]?.canCreateProjects, true)
    }

    func testTemporaryRetriesAreBoundedAndAuthenticationFailuresDoNotRetry() async throws {
        let cases: [(Error, Int)] = [
            (DaemonHTTPError(status: 502, message: "proxy unavailable"), 5),
            (DaemonHTTPError(status: 401, message: "unauthorized"), 1),
            (OblienError(kind: .authentication, status: 403, code: nil, message: "Forbidden", details: nil), 1),
            (URLError(.cancelled), 1)
        ]
        for (error, expectedAttempts) in cases {
            let stores = Stores(defaults: try defaults())
            var attempts = 0
            let queue = PreparationQueue(stores: stores, canResolve: { _ in true }, prepareWorkspace: { _ in
                attempts += 1
                throw error
            }, waitBeforeRetry: { _ in })
            queue.enqueue(workspaceId: workspace.id)
            try await eventually { queue.active.isEmpty }
            XCTAssertEqual(attempts, expectedAttempts)
            XCTAssertTrue(queue.pendingWorkspaceIDs.isEmpty, "A failed attempt requires an explicit retry")
            queue.resume()
            XCTAssertEqual(attempts, expectedAttempts, "Foreground must not restart a failed attempt")
        }
    }

    func testLegacyFailedRequestsAreNotReplayedWhenOpeningTheUpdatedApp() throws {
        let saved = try defaults()
        saved.set([workspace.id], forKey: "mindwire:pending-workspace-preparations:v1")
        saved.set(["old-agent"], forKey: "mindwire:pending-agent-preparations:v1")
        let stores = Stores(defaults: saved)
        let queue = PreparationQueue(stores: stores, canResolve: { _ in true }, prepareWorkspace: { _ in
            XCTFail("Legacy requests did not distinguish failed attempts from active work")
        })
        queue.resume()
        XCTAssertTrue(queue.pendingWorkspaceIDs.isEmpty)
        XCTAssertTrue(queue.pendingIDs.isEmpty)
        XCTAssertNil(saved.object(forKey: "mindwire:pending-workspace-preparations:v1"))
        XCTAssertNil(saved.object(forKey: "mindwire:pending-agent-preparations:v1"))
    }

    func testDeletingWorkspaceDuringStartupDelayPreventsAnotherAttempt() async throws {
        let stores = Stores(defaults: try defaults())
        var attempts = 0
        var retry: CheckedContinuation<Void, Never>?
        defer { retry?.resume() }
        let queue = PreparationQueue(stores: stores, canResolve: { _ in true }, prepareWorkspace: { _ in
            attempts += 1
            throw DaemonHTTPError(status: 503, message: "Starting")
        }, waitBeforeRetry: { _ in await withCheckedContinuation { retry = $0 } })
        queue.enqueue(workspaceId: workspace.id)
        try await eventually { retry != nil }
        queue.forget(workspaceId: workspace.id)
        retry?.resume(); retry = nil
        try await eventually { queue.active.isEmpty }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(queue.pendingWorkspaceIDs.isEmpty)
        XCTAssertTrue(PreparationQueue(stores: stores).pendingWorkspaceIDs.isEmpty)
    }

    private func configurePreparation(_ stores: Stores, repository: WorkspaceRepository,
                                      channel: WorkspaceDaemonFixture, coordinator: DaemonWorkCoordinator) {
        let releases = ReleaseCatalog(defaults: stores.defaults, fetch: {
            DaemonCatalog(version: "0.1.13", agents: [AgentDescriptor(id: .codex, name: "Codex", tagline: "Coding")])
        })
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { workspace in
            WorkspaceRegistryClient(workspace: workspace, stores: stores,
                http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator,
                releases: releases, installer: channel, backend: WorkspaceControlFixture())
        }, resolveWorkspace: { repository.get($0) })
        stores.preparation = PreparationQueue(stores: stores, canResolve: { repository.get($0) != nil })
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Workspace preparation did not reach the expected state")
    }
}

private actor WorkspaceDaemonFixture: DaemonChannel, DaemonInstaller {
    nonisolated let label = "workspace-daemon-fixture"
    private var health: DaemonHealth
    private var offline = false
    private var stoppedListener = false
    private var cancelledHealth = false
    private var binaryInstalled = true
    private var busy = ""
    private var hold = false
    private var ignoreInstall = false
    private var installationFails = false
    private var failedHealthChecks = 0
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var installs = 0
    private(set) var requiredUpdateLease = false
    private(set) var starts = 0
    private(set) var calls: [String] = []
    private(set) var forcedUpdate = false

    init(compatible: Bool, installed: Bool = true, version: String = "0.1.12") {
        offline = !installed
        binaryInstalled = installed
        health = .init(ok: true, version: version, workspaceMetadataVersion: compatible ? 1 : nil,
                       projectOperationsVersion: compatible ? 1 : nil)
    }
    var waiting: Bool { gate != nil }
    func setBusy(_ value: String) { busy = value }
    func disconnect() { offline = true }
    func stopService() { offline = false; stoppedListener = true }
    func cancelHealth() { cancelledHealth = true }
    func failNextHealthChecks(_ count: Int) { failedHealthChecks = count }
    func setNotificationPreferencesVersion(_ version: Int?) { health.notificationPreferencesVersion = version }
    func setServiceUpdateVersion(_ version: Int?) { health.serviceUpdateVersion = version }
    func holdInstallation() { hold = true }
    func ignoreInstallation() { ignoreInstall = true }
    func failInstallation(_ value: Bool) { installationFails = value }
    func finishInstallation() { gate?.resume(); gate = nil; hold = false }

    func startInstalled(daemonToken: String) async throws {
        starts += 1
        guard binaryInstalled else { throw DaemonBootstrapError.notInstalled }
        offline = false
        stoppedListener = false
    }

    func install(agentType: String, cwd: String, target: String, daemonToken: String,
                 requireUpdateLease: Bool, force: Bool,
                 onProgress: (@Sendable (DaemonInstallProgress) -> Void)?) async throws {
        installs += 1
        requiredUpdateLease = requireUpdateLease
        forcedUpdate = force
        if installationFails { throw BackendError.message("curl: (28) Connection timed out") }
        binaryInstalled = true
        onProgress?(.downloading(0.5))
        if hold { await withCheckedContinuation { gate = $0 } }
        if !ignoreInstall { health = .init(ok: true, version: target, workspaceMetadataVersion: 1, projectOperationsVersion: 1) }
        offline = false
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        calls.append(method + " " + path)
        if cancelledHealth { throw CancellationError() }
        if stoppedListener { throw DaemonHTTPError(status: 502, message: "Runtime proxy: connection refused") }
        if offline { throw URLError(.notConnectedToInternet) }
        let endpoint = String(path.split(separator: "?")[0])
        if endpoint == "/healthz", failedHealthChecks > 0 {
            failedHealthChecks -= 1
            throw DaemonHTTPError(status: 503, message: "Runtime proxy is still starting")
        }
        switch endpoint {
        case "/workspace", "/workspace/changes":
            return try json(WorkspaceMetadata(version: 1, workspaceId: "database", revision: 0, full: true,
                                             agents: [], projects: [], chats: [], deleted: []))
        case "/healthz": return try json(health)
        case "/service/update":
            return (200, busy.isEmpty ? #"{"idle":true,"updating":false,"activeOperations":0}"#
                : #"{"idle":false,"updating":false,"activeOperations":1}"#)
        case "/catalog":
            return try json(DaemonCatalog(version: health.version ?? "", agents: [
                AgentDescriptor(id: .codex, name: "Codex", tagline: "Coding"),
                AgentDescriptor(id: .claudeCode, name: "Claude", tagline: "Coding")
            ]))
        case "/chats":
            return (200, busy == "claude-chat" && path.contains("agent=claude-code")
                ? #"[{"chatId":"chat","lastStatus":"running"}]"# : "[]")
        case "/setup":
            return try json(DaemonSetupResult(ok: true, running: busy == "codex-setup" && path.contains("agent=codex"), steps: []))
        case "/workspace/operations":
            let operation = ProjectOperation(id: "clone", source: "clone", name: "App", path: "/work/app",
                status: "running", phase: "cloning", createdAt: "2026-09-16T00:00:00Z", updatedAt: "2026-09-16T00:00:00Z", sequence: 1, attempt: 1)
            return try json(["operations": busy == "project" ? [operation] : []])
        default: throw URLError(.unsupportedURL)
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> (status: Int, body: String) {
        (200, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
}

private final class WorkspaceAdoptionFixture: WorkspaceAdapter {
    let workspace: Workspace
    var present: Bool
    var deleted = false

    init(workspace: Workspace, present: Bool = false) { self.workspace = workspace; self.present = present }
    func owns(_ workspace: Workspace) -> Bool { workspace.id == self.workspace.id }
    func current() -> [Workspace] { present ? [workspace] : [] }
    func refresh() async {}
    func adopt(name: String, runtime: AgentRuntime, spec: WorkspaceSpec?) async -> Workspace? {
        guard runtime == workspace.runtime else { return nil }
        present = true
        return workspace
    }
    func rename(_ id: String, to name: String) async {}
    func delete(_ id: String) async throws { present = false; deleted = true }
    func confirmsDeletion(_ id: String) async -> Bool { deleted && id == workspace.id }
}
