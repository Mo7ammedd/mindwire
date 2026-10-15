import XCTest
@testable import Mindwire

@MainActor
final class DaemonWorkTests: XCTestCase {
    func testCancelledProbeDoesNotMarkAWorkingServiceUnavailable() {
        let suite = "cancelled-probe-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = DaemonWorkCoordinator(defaults: defaults)
        let key = DaemonWorkKey(workspaceId: "cloud")
        let health = DaemonHealth(ok: true, version: "0.1.38", workspaceMetadataVersion: 1)
        coordinator.recordHealth(health, for: key)
        for error in [CancellationError() as any Error, URLError(.cancelled)] {
            coordinator.recordFailure(error, for: key, revision: coordinator.probeRevision(key))
            XCTAssertEqual(coordinator.states[key]?.reachable, true)
            XCTAssertEqual(coordinator.states[key]?.health, health)
            XCTAssertNil(coordinator.states[key]?.connectionError)
        }
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Shared work did not reach the expected state")
    }

    func testServiceProgressKeepsMeasuredZeroAndDoesNotRegressDuringVerificationOrRetry() async throws {
        let work = DaemonWorkState()
        work.begin(.updatingDaemon)
        work.receive(.downloading(0))
        XCTAssertEqual(work.progressFraction, 0, "A measured zero must use a determinate bar")
        work.receive(.downloading(0.625))
        XCTAssertEqual(work.progressFraction, 0.625)
        work.receive(.uploading(nil))
        XCTAssertNil(work.progressFraction, "An API without byte counts must not invent an upload percentage")
        work.receive(.starting)
        work.receive(.verifying)
        work.receive(.downloading(0.9))
        work.receive(.starting)
        XCTAssertEqual(work.installProgress?.label, t("workspace.daemon.progress.verifying"))
        XCTAssertNil(work.progressFraction)

        let oldCallback = work.progressHandler()
        work.begin(.updatingDaemon)
        let currentCallback = work.progressHandler()
        oldCallback(.verifying)
        currentCallback(.downloading(0.25))
        try await eventually { work.progressFraction == 0.25 }
        XCTAssertEqual(work.installProgress?.label, t("workspace.daemon.progress.downloading"))
        work.running = false
        currentCallback(.uploading(0.5))
        await Task.yield()
        XCTAssertEqual(work.progressFraction, 0.25, "Callbacks after completion cannot alter the final state")
    }

    func testReopenedAgentsShareWorkspaceJobAndProgressDespiteCallerCancellation() async throws {
        let coordinator = DaemonWorkCoordinator()
        let key = DaemonWorkKey(workspaceId: "shared")
        var starts = 0
        var finish: CheckedContinuation<Void, Never>?
        let first = Task {
            try await coordinator.perform(key, activity: .updatingDaemon) { state in
                starts += 1
                state.progress = 0.42
                await withCheckedContinuation { finish = $0 }
            }
        }
        try await eventually { finish != nil }
        first.cancel() // Going back must not cancel the workspace's install.
        let reopened = Task {
            try await coordinator.perform(key) { _ in starts += 1 }
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(coordinator.states[key]?.activity, .updatingDaemon)
        XCTAssertEqual(coordinator.states[key]?.progress, 0.42)
        XCTAssertEqual(coordinator.states[key]?.running, true)
        finish?.resume()
        try await first.value
        try await reopened.value
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(coordinator.states[key]?.running, false)
    }

    func testOtherWorkspacesRemainIndependentAndFailureAllowsRetry() async throws {
        let coordinator = DaemonWorkCoordinator()
        let first = DaemonWorkKey(workspaceId: "one", agentType: "codex")
        let other = DaemonWorkKey(workspaceId: "two", agentType: "codex")
        var finish: CheckedContinuation<Void, Never>?
        let failed = Task {
            try await coordinator.perform(first, activity: .updatingTools) { _ in
                await withCheckedContinuation { finish = $0 }
                throw BackendError.message("Installer failed")
            }
        }
        try await eventually { finish != nil }
        var otherRan = false
        try await coordinator.perform(other) { _ in otherRan = true }
        XCTAssertTrue(otherRan)
        finish?.resume()
        do { try await failed.value; XCTFail("Expected the install failure") } catch {}
        XCTAssertEqual(coordinator.states[first]?.running, false)
        XCTAssertEqual(coordinator.states[first]?.error, "Installer failed")
        var retried = false
        try await coordinator.perform(first) { _ in retried = true }
        XCTAssertTrue(retried)
        XCTAssertNil(coordinator.states[first]?.error)
    }

    func testStaleStatusCannotEraseANewerUpdateAndPassiveReadsDeduplicate() async throws {
        let coordinator = DaemonWorkCoordinator()
        let key = DaemonWorkKey(workspaceId: "shared", agentType: "claude-code")
        var reads = 0
        var finish: CheckedContinuation<Void, Never>?
        let oldRead = Task {
            await coordinator.refresh(key, interval: 0) {
                reads += 1
                await withCheckedContinuation { finish = $0 }
                return .setup(.init(ok: true, running: false, started: true, steps: [], operation: "setup"))
            }
        }
        try await eventually { finish != nil }
        let duplicate = Task {
            await coordinator.refresh(key, interval: 0) {
                reads += 1
                return .setup(.init(ok: true, steps: []))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        do {
            try await coordinator.perform(key, activity: .updatingTools) { _ in
                throw BackendError.message("Update failed")
            }
        } catch {}
        finish?.resume()
        await oldRead.value
        await duplicate.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(coordinator.states[key]?.activity, .updatingTools)
        XCTAssertEqual(coordinator.states[key]?.error, "Update failed")

        await coordinator.refresh(key, interval: 0) {
            .setup(.init(ok: false, running: true, started: true, current: "codex", steps: [], operation: "update"))
        }
        XCTAssertEqual(coordinator.states[key]?.running, true)
        XCTAssertEqual(coordinator.states[key]?.activity, .updatingTools)
        XCTAssertNil(coordinator.states[key]?.error)
    }

    func testVersionBadgesOnlyOfferNewerReleasesAndOlderSetupPayloadStillDecodes() throws {
        let state = DaemonWorkState()
        state.installedVersion = "0.1.9"
        state.latestVersion = "0.1.12"
        XCTAssertTrue(state.updateAvailable)
        state.installedVersion = "0.1.13"
        XCTAssertFalse(state.updateAvailable)
        let old = try JSONDecoder().decode(DaemonSetupResult.self, from: Data(#"{"ok":false,"running":true,"steps":[]}"#.utf8))
        state.receive(old)
        XCTAssertEqual(state.activity, .installingTools)
        XCTAssertTrue(state.running)
    }

    func testConcurrentUpdateActionsPostOnceAndKeepNativeOperation() async throws {
        let channel = UpdateJobChannel()
        let session = DaemonSession(agentId: UUID().uuidString,
            transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        let first = Task { try await session.updateAgent() }
        for _ in 0..<200 {
            if await channel.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.toolsWork?.activity, .updatingTools)
        XCTAssertEqual(session.toolsWork?.running, true)
        let reopened = Task { try await session.updateAgent() }
        try await Task.sleep(for: .milliseconds(30))
        await channel.finish()
        try await first.value
        try await reopened.value
        let posts = await channel.posts
        XCTAssertEqual(posts, 1, "Reopening or double tapping must not queue another update after the first completes")
        XCTAssertEqual(session.toolsWork?.running, false)
        XCTAssertNil(session.toolsWork?.error)
    }

    func testExistingRunCanBeStoppedWhileUpdateIsPendingButNewTurnsWait() async throws {
        let channel = UpdateJobChannel()
        let session = DaemonSession(agentId: UUID().uuidString,
            transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        let update = Task { try await session.updateAgent() }
        for _ in 0..<200 {
            if await channel.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        do {
            _ = try await session.sendTurn(chatId: "chat", message: "Build", cwd: nil)
            XCTFail("A new turn must wait until the install finishes")
        } catch { XCTAssertEqual(error.localizedDescription, t("agentUpdates.busy")) }
        try await session.call { try await $0.cancelRun("run") }
        let pending = await channel.waiting
        let cancellations = await channel.cancellations
        XCTAssertTrue(pending, "Stop must return without waiting for the update")
        XCTAssertEqual(cancellations, 1)
        await channel.finish()
        try await update.value
    }

    func testUpdateDoesNotStartDuringARunningChat() async throws {
        let channel = UpdateJobChannel(runningChats: true)
        let session = DaemonSession(agentId: UUID().uuidString,
            transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        do { try await session.updateAgent(); XCTFail("A running chat must prevent a CLI update") }
        catch { XCTAssertEqual(error.localizedDescription, t("agentUpdates.chatsRunning")) }
        let posts = await channel.posts
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(session.toolsWork?.running, false)
    }

    func testUpdateCannotCallOldDaemonsLatestInstaller() async throws {
        let channel = UpdateJobChannel(supportsPolicy: false)
        let session = DaemonSession(agentId: UUID().uuidString,
            transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        do { try await session.updateAgent(); XCTFail("Old services need a policy upgrade first") }
        catch { XCTAssertEqual(error.localizedDescription, t("agentUpdates.policyRequired")) }
        let posts = await channel.posts
        XCTAssertEqual(posts, 0)
    }
}

private actor UpdateJobChannel: DaemonChannel {
    nonisolated let label = "update-job-fixture"
    private(set) var posts = 0
    private(set) var cancellations = 0
    private let runningChats: Bool
    private let supportsPolicy: Bool
    private var gate: CheckedContinuation<Void, Never>?
    init(runningChats: Bool = false, supportsPolicy: Bool = true) {
        self.runningChats = runningChats
        self.supportsPolicy = supportsPolicy
    }
    var waiting: Bool { gate != nil }
    func finish() { gate?.resume(); gate = nil }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        if method == "GET", path == "/agent?agent=codex" {
            var info = DaemonAgentInfo(version: "0.1.16", agentType: "codex", name: "Codex",
                schema: .empty, installedVersion: "1.2.3", configured: true,
                authMethods: try JSONDecoder().decode([DaemonAuthMethod].self,
                    from: Data(#"[{"id":"login","label":"Sign in","interactive":true}]"#.utf8)),
                authStatus: .init(configured: true))
            if supportsPolicy { info.software = .fixture(recommended: "1.3.0") }
            return (200, String(decoding: try JSONEncoder().encode(info), as: UTF8.self))
        }
        if method == "GET", path == "/chats?agent=codex" {
            return (200, runningChats ? #"[{"chatId":"chat","lastStatus":"running"}]"# : "[]")
        }
        if method == "POST", path == "/runs/run/cancel?agent=codex" {
            cancellations += 1
            return (200, "{}")
        }
        if method == "POST", path == "/update?agent=codex" {
            posts += 1
            await withCheckedContinuation { gate = $0 }
        } else if path != "/setup?agent=codex" {
            throw URLError(.unsupportedURL)
        }
        let status = DaemonSetupResult(ok: posts > 0 && gate == nil, running: gate != nil,
            started: posts > 0, steps: [], operation: posts > 0 ? "update" : nil)
        return (200, String(decoding: try JSONEncoder().encode(status), as: UTF8.self))
    }
}
