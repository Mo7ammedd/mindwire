import XCTest
@testable import Mindwire

@MainActor
final class HarnessDependencyTests: XCTestCase {
    func testInstalledCLIRepairsMissingDependencyThroughSetupWithoutUpdate() async throws {
        let channel = DependencyRepairChannel()
        let info = try await AgentInstallation.ensure(
            transport: ExecDaemonTransport(channel: channel, agentType: "codex"), work: DaemonWorkState())
        XCTAssertFalse(info.software?.needsSetup == true)
        XCTAssertEqual(info.installedVersion, "0.155.0")
        let mutations = await channel.mutations
        XCTAssertEqual(mutations, ["POST /setup"])
    }

    func testInstalledVersionCannotHideAFailedDependencyRepair() async throws {
        let channel = DependencyRepairChannel(repairWorks: false)
        do {
            _ = try await AgentInstallation.ensure(
                transport: ExecDaemonTransport(channel: channel, agentType: "codex"), work: DaemonWorkState())
            XCTFail("Missing dependency must not be marked ready")
        } catch { XCTAssertEqual(error.localizedDescription, t("agentUpdates.dependenciesMissing", ["tools": "bubblewrap"])) }
    }

    func testDependencyRepairDefersWhileCurrentChatIsRunning() async throws {
        let channel = DependencyRepairChannel(running: true)
        let info = try await AgentInstallation.ensure(
            transport: ExecDaemonTransport(channel: channel, agentType: "codex"), work: DaemonWorkState())
        XCTAssertTrue(info.software?.needsSetup == true)
        let mutations = await channel.mutations
        XCTAssertTrue(mutations.isEmpty, "Current history and Stop must remain reachable")
    }
}

private actor DependencyRepairChannel: DaemonChannel {
    nonisolated let label = "dependency-repair-fixture"
    let repairWorks: Bool
    let running: Bool
    private var repaired = false
    private(set) var mutations: [String] = []

    init(repairWorks: Bool = true, running: Bool = false) {
        self.repairWorks = repairWorks
        self.running = running
    }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        let endpoint = String(path.split(separator: "?")[0])
        if method == "POST" {
            mutations.append(method + " " + endpoint)
            guard endpoint == "/setup" else { throw URLError(.unsupportedURL) }
            repaired = repairWorks
        }
        switch endpoint {
        case "/setup": return (200, #"{"ok":true,"running":false,"steps":[]}"#)
        case "/chats": return (200, running ? #"[{"chatId":"working","lastStatus":"running"}]"# : "[]")
        case "/agent":
            var software = DaemonHarnessSoftware.fixture(installed: "0.155.0", recommended: "0.155.0")
            software.missingDependencies = repaired ? [] : ["bubblewrap"]
            let info = DaemonAgentInfo(version: "0.1.16", agentType: "codex", name: "Codex", schema: .empty,
                installedVersion: "0.155.0", software: software, configured: true)
            return (200, String(decoding: try JSONEncoder().encode(info), as: UTF8.self))
        default: throw URLError(.unsupportedURL)
        }
    }
}
