import XCTest
@testable import Mindwire

@MainActor
final class ComputerServiceUpdateTests: XCTestCase {
    private let workspace = Workspace(id: "paired-update", name: "My Mac",
        runtime: .server(serverId: "paired-mac"), createdAt: "now")

    private func stores() throws -> Stores {
        let suite = "MindwireTests.computer-update.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func client(_ channel: ComputerUpdateFixture, stores: Stores,
                        coordinator: DaemonWorkCoordinator) -> WorkspaceRegistryClient {
        WorkspaceRegistryClient(workspace: workspace, stores: stores,
            http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator,
            releases: ReleaseCatalog(defaults: stores.defaults, fetch: {
                .init(version: "0.1.26", agents: [.init(id: .codex, name: "Codex", tagline: "Coding")])
            }), installer: ComputerDaemonInstaller(channel: channel, poll: {}, pollLimit: 3))
    }

    func testAutomaticUpdateWaitsForMindwireTerminalWithoutRepeatingTheRequest() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let channel = ComputerUpdateFixture(), client = client(channel, stores: stores, coordinator: coordinator)
        do {
            try await client.updateDaemon(automatic: true, target: "0.1.26")
            XCTFail("The terminal must keep this update pending")
        } catch let pending as DaemonUpdatePending {
            XCTAssertEqual(pending.operation.status, "waiting")
            XCTAssertEqual(pending.operation.activity?.openTerminals, 1)
        }
        let calls = await channel.calls
        XCTAssertEqual(calls.filter { $0 == "POST /computer/update" }.count, 1,
                       "A busy computer must receive the request, rather than leaving it only on the phone")
        let submitted = try XCTUnwrap(calls.firstIndex(of: "POST /computer/update"))
        let activityRead = try XCTUnwrap(calls.firstIndex(of: "GET /service/update"))
        XCTAssertLessThan(submitted, activityRead)
        let state = try XCTUnwrap(coordinator.states[.init(workspaceId: workspace.id)])
        XCTAssertFalse(state.running)
        XCTAssertTrue(state.updateWaiting)
        XCTAssertNil(state.error)
        XCTAssertEqual(WorkspaceDaemonStatusLabel.title(for: state, preparing: false, scheduled: false),
                       t("workspace.daemon.waitingTerminalStatus"))

        client.invalidateChecks()
        try await client.prepare(allowInstall: false)
        XCTAssertEqual(state.updateOperation?.activity?.openTerminals, 1)
        let rechecked = await channel.calls
        XCTAssertEqual(rechecked.filter { $0 == "POST /computer/update" }.count, 1,
                       "Recheck observes the existing update without submitting it again")
    }

    func testManualUpdatePromotesTheSameAutomaticRequestAndRestartsWithoutWaitingForWork() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let channel = ComputerUpdateFixture(), client = client(channel, stores: stores, coordinator: coordinator)
        await channel.setStatus("waiting")
        try await client.updateDaemon(automatic: false, target: "0.1.26")
        let forces = await channel.postedForces
        XCTAssertEqual(forces, [true])
        let calls = await channel.calls
        XCTAssertEqual(calls.filter { $0 == "POST /computer/update" }.count, 1)
        XCTAssertFalse(calls.contains { $0.hasPrefix("DELETE /workspace/terminals/") },
                       "Current services own restart policy; the app must not close unrelated work itself")
        XCTAssertEqual(coordinator.states[.init(workspaceId: workspace.id)]?.installedVersion, "0.1.26")
        XCTAssertFalse(coordinator.states[.init(workspaceId: workspace.id)]?.updateWaiting ?? true)
    }

    func testManualLegacyUpdateClosesOnlyDaemonHostedTerminalsAfterDownload() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let channel = ComputerUpdateFixture(), client = client(channel, stores: stores, coordinator: coordinator)
        await channel.useLegacyService()
        try await client.updateDaemon(automatic: false, target: "0.1.26")
        let calls = await channel.calls
        XCTAssertEqual(calls.filter { $0 == "POST /computer/update" }.count, 1)
        XCTAssertEqual(calls.filter { $0.hasPrefix("DELETE ") }, ["DELETE /workspace/terminals/open-terminal"])
        XCTAssertFalse(calls.contains { $0.contains("/workspace/exec") })
        XCTAssertEqual(coordinator.states[.init(workspaceId: workspace.id)]?.installedVersion, "0.1.26")
    }

    func testUpdateAllAndRelaunchJoinTheComputerQueueThenVerifyCompletion() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        stores.defaults.set(false, forKey: StorageKey.automaticServiceUpdates)
        let channel = ComputerUpdateFixture(), client = client(channel, stores: stores, coordinator: coordinator)
        await channel.deferManualUpdates()
        var date = Date()
        let catalog = DaemonCatalog(version: "0.1.26", agents: [.init(id: .codex, name: "Codex", tagline: "Coding")])
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { _ in true },
            now: { date }, update: { _, automatic, target in
                try await client.updateDaemon(automatic: automatic, target: target)
            }, fetchCatalog: { catalog }, readWorkspace: { _ in
                client.invalidateChecks()
                try? await client.prepare(allowInstall: false)
            })
        let checked = await queue.updateAll([workspace])
        XCTAssertTrue(checked)
        XCTAssertTrue(queue.active.isEmpty)
        XCTAssertEqual(queue.requested, [workspace.id])
        XCTAssertEqual(queue.waitingCount, 1)

        // A new client has no in-memory operation, but can recover it from the computer.
        let reloaded = DaemonWorkCoordinator(defaults: stores.defaults)
        let reopened = self.client(channel, stores: stores, coordinator: reloaded)
        XCTAssertEqual(reloaded.states[.init(workspaceId: workspace.id)]?.updateOperation?.id, "computer-update")
        XCTAssertNil(reloaded.states[.init(workspaceId: workspace.id)]?.reachable)
        XCTAssertNil(reloaded.states[.init(workspaceId: workspace.id)]?.updateOperation?.activity,
                     "A saved receipt must not claim that a terminal is still running")
        await channel.failNextHealthCheck()
        do {
            try await reopened.updateDaemon(automatic: false, target: "0.1.26")
            XCTFail("The computer is in its restart window")
        } catch let pending as DaemonUpdatePending {
            XCTAssertEqual(pending.operation.id, "computer-update")
        }
        try await reopened.prepare(allowInstall: false)
        XCTAssertEqual(reloaded.states[.init(workspaceId: workspace.id)]?.updateOperation?.status, "waiting")
        var observations = 0
        let next = ServiceUpdateScheduler(stores: stores, coordinator: reloaded, canResolve: { _ in true }, now: { date },
            update: { _, _, _ in XCTFail("An accepted request must be observed, never enter installation again") },
            observeUpdate: { _ in
                defer { observations += 1 }
                try await reopened.observeDaemonUpdate()
            })
        next.reconcile([workspace])
        try await eventually { observations == 1 }
        XCTAssertTrue(next.active.isEmpty)
        XCTAssertFalse(reloaded.states[.init(workspaceId: workspace.id)]?.running ?? true)
        let calls = await channel.calls
        XCTAssertEqual(calls.filter { $0 == "POST /computer/update" }.count, 1)
        XCTAssertTrue(next.requested.contains(workspace.id))

        await channel.complete()
        await channel.failNextHealthCheck()
        date.addTimeInterval(16)
        next.reconcile([workspace])
        try await eventually { observations == 2 }
        XCTAssertTrue(next.requested.contains(workspace.id), "A restart disconnect cannot consume an accepted update")
        XCTAssertNil(reloaded.states[.init(workspaceId: workspace.id)]?.error)
        date.addTimeInterval(16)
        next.reconcile([workspace])
        try await eventually { observations == 3 }
        XCTAssertTrue(next.requested.isEmpty)
        XCTAssertEqual(reloaded.states[.init(workspaceId: workspace.id)]?.installedVersion, "0.1.26")
        XCTAssertEqual(reloaded.states[.init(workspaceId: workspace.id)]?.updateOperation?.status, "complete")
        XCTAssertFalse(reloaded.states[.init(workspaceId: workspace.id)]?.updateWaiting ?? true)
    }

    func testLongDownloadStaysPendingAndAuthorizationErrorsAreNotSwallowed() async throws {
        let channel = ComputerUpdateFixture()
        await channel.setStatus("downloading")
        let installer = ComputerDaemonInstaller(channel: channel, poll: {}, pollLimit: 2)
        do {
            try await installer.install(agentType: "", cwd: "", target: "0.1.26", daemonToken: "", onProgress: nil)
            XCTFail("The controller is still downloading")
        } catch let pending as DaemonUpdatePending {
            XCTAssertEqual(pending.operation.status, "downloading")
        }
        await channel.setPollError(401)
        do {
            try await installer.install(agentType: "", cwd: "", target: "0.1.26", daemonToken: "", onProgress: nil)
            XCTFail("Authorization failure must be visible")
        } catch let error as DaemonHTTPError { XCTAssertEqual(error.status, 401) }
        let calls = await channel.calls
        XCTAssertFalse(calls.contains("POST /computer/update"), "An existing download must not be restarted")
    }

    func testFailedUpdateRemainsVisibleAfterHealthRecheck() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let channel = ComputerUpdateFixture(), client = client(channel, stores: stores, coordinator: coordinator)
        await channel.setStatus("failed", error: "The release checksum did not match.")
        try await client.prepare(allowInstall: false)
        let state = try XCTUnwrap(coordinator.states[.init(workspaceId: workspace.id)])
        XCTAssertTrue(state.reachable == true)
        XCTAssertEqual(state.error, "The release checksum did not match.")
        client.invalidateChecks()
        try await client.prepare(allowInstall: false)
        XCTAssertEqual(state.updateOperation?.error, "The release checksum did not match.")
        XCTAssertEqual(state.error, "The release checksum did not match.")
    }

    func testPreparationCachesControllerStatusButManualRecheckRefreshesIt() async throws {
        let stores = try stores(), coordinator = DaemonWorkCoordinator(defaults: stores.defaults)
        let channel = ComputerUpdateFixture(), client = client(channel, stores: stores, coordinator: coordinator)
        for _ in 0..<5 { try await client.prepare(allowInstall: false) }
        var calls = await channel.calls
        XCTAssertEqual(calls.filter { $0 == "GET /computer/update" }.count, 1)
        client.invalidateChecks()
        try await client.prepare(allowInstall: false)
        calls = await channel.calls
        XCTAssertEqual(calls.filter { $0 == "GET /computer/update" }.count, 2)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The update queue did not settle")
    }
}

private actor ComputerUpdateFixture: DaemonChannel {
    nonisolated let label = "computer-update-fixture"
    private(set) var calls: [String] = []
    private(set) var postedForces: [Bool] = []
    private var status = "idle"
    private var version = "0.1.25"
    private var updateError: String?
    private var pollError: Int?
    private var healthCheckFails = false
    private var supportsForce = true
    private var forced = false
    private var manualDeferred = false
    private var terminalOpen = true

    func setStatus(_ value: String, error: String? = nil) { status = value; updateError = error }
    func setPollError(_ value: Int) { pollError = value }
    func complete() { status = "complete"; version = "0.1.26" }
    func failNextHealthCheck() { healthCheckFails = true }
    func useLegacyService() { supportsForce = false }
    func deferManualUpdates() { manualDeferred = true }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        calls.append(method + " " + path)
        switch path {
        case "/healthz":
            if healthCheckFails { healthCheckFails = false; throw URLError(.cannotConnectToHost) }
            return (200, "{\"ok\":true,\"version\":\"\(version)\",\"workspaceMetadataVersion\":1,\"projectOperationsVersion\":1,\"serviceUpdateVersion\":1}")
        case "/computer/update":
            if let pollError { return (pollError, #"{"error":"The computer rejected this device."}"#) }
            if method == "POST" {
                let body = try JSONSerialization.jsonObject(with: jsonBody ?? Data()) as? [String: Any]
                let force = body?["force"] as? Bool ?? false
                postedForces.append(force)
                forced = force && supportsForce
                status = "waiting"
                if forced && !manualDeferred { complete() }
            }
            var value: [String: Any] = ["id": "computer-update", "version": "0.1.26", "status": status]
            if supportsForce { value["force"] = forced }
            if let updateError { value["error"] = updateError }
            return (200, String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        case "/service/update":
            return (200, #"{"idle":false,"updating":false,"activeOperations":1}"#)
        case "/workspace/terminals":
            if !terminalOpen { return (200, "[]") }
            return (200, #"[{"id":"open-terminal","directory":"/Users/test","title":"zsh","columns":80,"rows":24,"running":true,"createdAt":"2026-09-25T09:55:10Z"}]"#)
        case "/workspace/terminals/open-terminal":
            XCTAssertEqual(method, "DELETE")
            terminalOpen = false
            complete()
            return (200, #"{"ok":true}"#)
        default: throw URLError(.unsupportedURL)
        }
    }
}

/// Opt-in: an isolated, released computer service, paired through the same SSH
/// transport as the app. The host fixture approves only this test's invitation.
@MainActor
final class ComputerServiceUpdateLiveTests: XCTestCase {
    func testReleasedComputerManualUpdateClosesHostedTerminalAndKeepsPairing() async throws {
        guard let path = ProcessInfo.processInfo.environment["MINDWIRE_COMPUTER_UPDATE_FIXTURE"] else {
            throw XCTSkip("Start a disposable older computer service and provide its private pairing fixture.")
        }
        let fixtures = try JSONDecoder().decode([String: ComputerInvitation].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let invitation = try XCTUnwrap(fixtures["websocket"] ?? fixtures["direct"])
        let paired = try await ComputerPairingService.pair(String(decoding: JSONEncoder().encode(invitation), as: UTF8.self),
            deviceName: "Mindwire integration iPhone") { _ in }
        var computer = paired.computer
        computer.routes = invitation.routes
        addTeardownBlock { Keychain.delete(computer.keyRef); Keychain.delete(computer.tokenRef) }
        let channel = ComputerDaemonChannel(computer: computer)
        addTeardownBlock { await channel.close() }
        let http = DaemonHTTP(channel: channel, agentType: "")
        let target = ProcessInfo.processInfo.environment["MINDWIRE_COMPUTER_UPDATE_TARGET"] ?? "0.1.26"
        let initial: DaemonHealth = try await http.decode("GET", "/healthz", quiet: true)
        XCTAssertFalse(DaemonRelease.satisfies(initial.version, target: target), "The fixture must start on an older published release")
        struct Runtime: Decodable { let pid: Int; let fingerprint: String; let computerId: String }
        let before: Runtime = try await http.decode("GET", "/computer", quiet: true)
        let terminalId = "update-test-" + UUID().uuidString
        let terminal: DaemonTerminalState = try await http.decode("POST", "/workspace/terminals", json: [
            "id": terminalId, "directory": paired.host.directory, "columns": 80, "rows": 24
        ], quiet: true)
        XCTAssertTrue(terminal.running)
        addTeardownBlock { _ = try? await http.run("DELETE", "/workspace/terminals/\(terminalId)", json: nil, quiet: true) }

        let suite = "MindwireTests.released-computer-update.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let connection = stores.savePairedComputer(.init(invitation: paired.invitation, computer: computer, host: paired.host), name: "Update test Mac")
        let workspace = try XCTUnwrap(stores.workspaces(forServerId: connection.id).first)
        let coordinator = DaemonWorkCoordinator(defaults: defaults)
        let client = WorkspaceRegistryClient(workspace: workspace, stores: stores,
            http: http, coordinator: coordinator, installer: ComputerDaemonInstaller(channel: channel))
        var date = Date()
        let queue = ServiceUpdateScheduler(stores: stores, coordinator: coordinator, canResolve: { $0 == workspace.id },
            now: { date }, update: { _, automatic, target in
                try await client.updateDaemon(automatic: automatic, target: target)
            }, observeUpdate: { _ in
                try await client.observeDaemonUpdate()
            }, fetchCatalog: {
                .init(version: target, agents: [.init(id: .codex, name: "Codex", tagline: "Coding")])
            }, readWorkspace: { _ in
                client.invalidateChecks()
                try? await client.prepare(allowInstall: false)
            })
        do {
            try await client.updateDaemon(automatic: true, target: target)
            XCTFail("Automatic updates must wait for the hosted terminal")
        } catch is DaemonUpdatePending {}
        let work = try XCTUnwrap(coordinator.states[.init(workspaceId: workspace.id)])
        XCTAssertEqual(work.updateOperation?.status, "waiting")
        XCTAssertEqual(work.updateOperation?.activity?.openTerminals, 1)
        let requestId = try XCTUnwrap(work.updateOperation?.id)
        XCTAssertNil(work.error)
        print("Published computer update: automatic request waits for its hosted terminal.")

        // Dropping the phone's connection must not cancel or duplicate the request.
        await channel.reconnect()
        let reconnected: Runtime = try await http.decode("GET", "/computer", quiet: true)
        XCTAssertEqual(reconnected.pid, before.pid)
        let stillRunning: DaemonTerminalState = try await http.decode("GET", "/workspace/terminals/\(terminalId)", quiet: true)
        XCTAssertTrue(stillRunning.running)
        let observed = try await ComputerDaemonInstaller(channel: channel).updateOperation()
        XCTAssertEqual(observed?.id, requestId)

        let checked = await queue.updateAll([workspace])
        XCTAssertTrue(checked)
        for _ in 0..<60 {
            date.addTimeInterval(16)
            queue.reconcile([workspace])
            while !queue.active.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            if queue.requested.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(queue.requested.isEmpty)
        XCTAssertNil(work.error)
        XCTAssertEqual(work.installedVersion, target)
        let after: Runtime = try await http.decode("GET", "/computer", quiet: true)
        XCTAssertNotEqual(after.pid, before.pid)
        XCTAssertEqual(after.fingerprint, before.fingerprint)
        XCTAssertEqual(after.computerId, before.computerId)
        let completed = try await ComputerDaemonInstaller(channel: channel).updateOperation()
        XCTAssertEqual(completed?.id, requestId)
        XCTAssertEqual(completed?.status, "complete")
        XCTAssertEqual(work.updateOperation?.status, "complete")
        print("Published computer update: verified v\(target), reconnected over SSH, and retained the original pairing and request.")
    }
}
