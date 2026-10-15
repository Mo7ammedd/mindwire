import XCTest
@testable import Mindwire

final class CloudExecTests: XCTestCase {
    func testCompletedCommandsUseTheirActualExitStatusDespiteRuntimeTimeoutCode() throws {
        for status in [0, 1, 9, 124, 127, 130, 255] {
            let command = try CloudExecCommand(["bash", "-c", "exit \(status)"])
            let stdout = "first line\r\nمرحبا 👋\r\n"
            let result = try command.decode(.init(exitCode: 124,
                stdout: stdout + command.marker + "\(status)>>", stderr: "a diagnostic"))
            XCTAssertEqual(result.exitCode, status)
            XCTAssertEqual(result.stdout, stdout)
            XCTAssertEqual(result.stderr, "a diagnostic")
        }
    }

    func testMissingMalformedAndTruncatedReceiptsNeverBecomeSuccess() throws {
        let command = try CloudExecCommand(["git", "status"])
        let other = try CloudExecCommand(["git", "status"])
        for output in ["partial output", command.marker + "0>", command.marker + "-1>>",
                       command.marker + "256>>", command.marker + "00>>", command.marker + "0>>unexpected",
                       other.marker + "0>>"] {
            XCTAssertThrowsError(try command.decode(.init(exitCode: 0, stdout: output, stderr: "")))
        }
        XCTAssertThrowsError(try command.decode(.init(exitCode: 0,
            stdout: command.marker + "0>>", stderr: "", truncated: true)))
    }

    func testReceiptDoesNotStripCommandOutputOrAcceptAnotherRequestsMarker() throws {
        let command = try CloudExecCommand(["printf", "%s", "literal"])
        let output = "literal <<MINDWIRE_EXIT_other:0>> without newline"
        let result = try command.decode(.init(exitCode: nil,
            stdout: output + command.marker + "0>>\r\n", stderr: ""))
        XCTAssertEqual(result.stdout, output)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertThrowsError(try CloudExecCommand([]))
        XCTAssertThrowsError(try CloudExecCommand([""]))
        XCTAssertThrowsError(try CloudExecCommand(["echo", "invalid\0argument"]))
    }

    func testCancelledServiceRequestKeepsItsCancellationIdentity() async throws {
        for error in [CancellationError() as any Error, URLError(.cancelled)] {
            let channel = URLSessionDaemonChannel { _, _, _, _ in throw error }
            do {
                _ = try await channel.perform(method: "GET", path: "/healthz", jsonBody: nil)
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error.isRequestCancellation)
            }
        }
    }

    @MainActor
    func testCancelledRegistryPreparationKeepsLastVerifiedServiceHealth() async throws {
        let suite = "cancelled-cloud-prepare-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let coordinator = DaemonWorkCoordinator(defaults: defaults)
        let workspace = Workspace(id: "cancelled", name: "Workspace", runtime: .server(serverId: "fixture"), createdAt: isoNow())
        let key = DaemonWorkKey(workspaceId: workspace.id)
        let health = DaemonHealth(ok: true, version: "0.1.38", workspaceMetadataVersion: 1)
        coordinator.recordHealth(health, for: key)
        coordinator.invalidateChecks(key)
        let channel = URLSessionDaemonChannel { _, _, _, _ in throw URLError(.cancelled) }
        let remote = WorkspaceRegistryClient(workspace: workspace, stores: stores,
            http: DaemonHTTP(channel: channel, agentType: ""), coordinator: coordinator)
        do {
            try await remote.prepare(allowInstall: false)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error.isRequestCancellation) }
        XCTAssertEqual(coordinator.states[key]?.reachable, true)
        XCTAssertEqual(coordinator.states[key]?.health, health)
        XCTAssertNil(coordinator.states[key]?.connectionError)
    }
}
