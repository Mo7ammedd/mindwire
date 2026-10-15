import XCTest
@testable import Mindwire

extension DaemonHarnessSoftware {
    static func fixture(installed: String = "1.2.3", recommended: String = "1.2.3",
                        compatibility: String = "supported", requiresService: Bool = false) -> Self {
        .init(policyVersion: 1, installedVersion: installed, recommendedVersion: recommended,
              latestVersion: recommended, compatibility: compatibility, managed: true,
              updateAvailable: installed != recommended, requiresDaemonUpdate: requiresService,
              catalogRevision: 1, catalogSource: "bundled", catalogStale: false)
    }
}

@MainActor
final class HarnessCompatibilityTests: XCTestCase {
    private func coordinator() throws -> DaemonWorkCoordinator {
        let suite = "harness-policy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return DaemonWorkCoordinator(defaults: defaults)
    }

    func testOldAndUnknownPoliciesCannotUnlockUnrestrictedInstaller() throws {
        var info = DaemonAgentInfo(version: "0.1.15", agentType: "codex", name: "Codex",
                                   schema: .empty, installedVersion: "", configured: false)
        XCTAssertThrowsError(try AgentInstallation.requireManagedInstaller(info))
        info.software = .fixture(installed: "")
        XCTAssertNoThrow(try AgentInstallation.requireManagedInstaller(info))
        let unknown = try JSONDecoder().decode(DaemonHarnessSoftware.self, from: Data("""
        {"policyVersion":99,"installedVersion":"1.2.3","recommendedVersion":"1.3.0",
         "compatibility":"future_status","managed":true,"updateAvailable":true,
         "requiresDaemonUpdate":false,"catalogRevision":1,"catalogSource":"remote","catalogStale":false}
        """.utf8))
        XCTAssertFalse(unknown.canUpdate)
        info.software = unknown
        XCTAssertThrowsError(try AgentInstallation.requireManagedInstaller(info))
    }

    func testAgentBadgeUsesDaemonDecisionInsteadOfComparingUpstreamLatest() throws {
        let state = DaemonWorkState()
        state.installedVersion = "1.2.3"
        state.latestVersion = "9.0.0"
        state.software = .fixture(requiresService: true)
        XCTAssertFalse(state.updateAvailable, "A newer upstream CLI can require a different daemon")
        state.software = .fixture(recommended: "1.3.0")
        XCTAssertTrue(state.updateAvailable)
    }

    func testAllPersonasShareCatalogCheckAndManualRefreshBypassesCache() async throws {
        let work = try coordinator()
        let key = DaemonWorkKey(workspaceId: "workspace", agentType: "codex")
        var reads = 0
        let read: @MainActor () async throws -> DaemonHarnessSoftware? = {
            reads += 1
            try await Task.sleep(for: .milliseconds(20))
            return .fixture(recommended: "1.3.0")
        }
        async let a: Void = work.refreshSoftware(key, read: read)
        async let b: Void = work.refreshSoftware(key, read: read)
        _ = await (a, b)
        await work.refreshSoftware(key, read: read)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(work.states[key]?.updateAvailable == true)
        await work.refreshSoftware(key, force: true, read: read)
        XCTAssertEqual(reads, 2)
        let before = work.states[key]?.software
        await work.refreshSoftware(key, force: true) { throw URLError(.networkConnectionLost) }
        XCTAssertEqual(work.states[key]?.software, before, "An outage preserves the last daemon decision")
    }

    func testSlowCatalogReadCannotUndoACompletedInstallation() async throws {
        let work = try coordinator()
        let key = DaemonWorkKey(workspaceId: "workspace", agentType: "codex")
        var started = false
        let read = Task {
            await work.refreshSoftware(key) {
                started = true
                try await Task.sleep(for: .milliseconds(50))
                return .fixture(recommended: "1.3.0")
            }
        }
        while !started { await Task.yield() }
        try await work.perform(key, activity: .updatingTools) { state in
            state.software = .fixture(installed: "1.3.0", recommended: "1.3.0")
        }
        await read.value
        XCTAssertEqual(work.states[key]?.software?.installedVersion, "1.3.0")
        XCTAssertFalse(work.states[key]?.updateAvailable ?? true)
    }

    func testIncompatibleVersionBlocksNewTurnsWithoutBlockingStop() async throws {
        let channel = IncompatibleHarnessChannel()
        let session = DaemonSession(agentId: UUID().uuidString,
            transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        await session.load()
        XCTAssertEqual(session.phase, .ready, "History and settings remain accessible")
        do { _ = try await session.sendTurn(chatId: "chat", message: "hello", cwd: nil); XCTFail("Admitted incompatible CLI") }
        catch { XCTAssertEqual(error.localizedDescription, "Update the service for this CLI.") }
        try await session.call { try await $0.cancelRun("existing") }
        let stops = await channel.stops
        XCTAssertEqual(stops, 1)
    }
}

private actor IncompatibleHarnessChannel: DaemonChannel {
    nonisolated let label = "incompatible-harness"
    private(set) var stops = 0
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        if method == "GET", path == "/setup?agent=codex" {
            return (200, #"{"ok":false,"running":false,"started":false,"steps":[]}"#)
        }
        if path == "/agent?agent=codex" {
            var info = DaemonAgentInfo(version: "0.1.16", agentType: "codex", name: "Codex",
                schema: .empty, installedVersion: "2.0.0", configured: true,
                authMethods: try JSONDecoder().decode([DaemonAuthMethod].self,
                    from: Data(#"[{"id":"login","label":"Sign in","interactive":true}]"#.utf8)),
                authStatus: .init(configured: true))
            info.software = .fixture(installed: "2.0.0", compatibility: "incompatible", requiresService: true)
            info.software?.message = "Update the service for this CLI."
            return (200, String(decoding: try JSONEncoder().encode(info), as: UTF8.self))
        }
        if method == "POST", path == "/runs/existing/cancel?agent=codex" { stops += 1; return (200, "{}") }
        throw URLError(.unsupportedURL)
    }
}
