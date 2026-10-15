import XCTest
@testable import Mindwire

@MainActor
final class DaemonServicePreparationTests: XCTestCase {
    func testNewReleaseNeverUpdatesDuringPreparationEvenWhenIdle() async throws {
        let current = DaemonHealth(ok: true, version: "0.1.15")
        let work = DaemonWorkState()
        work.installedVersion = "0.1.15"
        work.latestVersion = "0.1.16"
        for _ in 0..<3 {
            let result = try await DaemonServicePreparation.run(current: current, latest: "0.1.16", work: work,
                startInstalled: { XCTFail("Already running") },
                install: { _ in XCTFail("Navigation must not replace the service") },
                requireIdle: { _ in XCTFail("No replacement was requested") },
                health: { XCTFail("Already have verified health"); return current })
            XCTAssertEqual(result.version, "0.1.15")
            XCTAssertTrue(work.updateAvailable)
        }
    }

    func testBusyExplicitUpdateDoesNotInstallOrQueueALaterUpdate() async throws {
        let current = DaemonHealth(ok: true, version: "0.1.15")
        let work = DaemonWorkState()
        do {
            _ = try await DaemonServicePreparation.run(current: current, latest: "0.1.16", work: work,
                updateRequested: true, startInstalled: {}, install: { _ in XCTFail("Busy service replaced") },
                requireIdle: { _ in throw BackendError.message("busy") }, health: { current })
            XCTFail("Busy update should explain why it cannot run")
        } catch { XCTAssertEqual(error.localizedDescription, "busy") }
        _ = try await DaemonServicePreparation.run(current: current, latest: "0.1.16", work: work,
            startInstalled: {}, install: { _ in XCTFail("A previous request must not become an automatic update") },
            requireIdle: { _ in }, health: { current })
    }

    func testExplicitUpdateChecksIdleThenVerifiesInstalledVersion() async throws {
        var events: [String] = []
        let result = try await DaemonServicePreparation.run(
            current: .init(ok: true, version: "0.1.15"), latest: "0.1.16", work: DaemonWorkState(),
            updateRequested: true, startInstalled: { XCTFail("Already running") },
            install: { events.append("install " + $0) },
            requireIdle: { _ in events.append("idle") },
            health: { events.append("verify"); return .init(ok: true, version: "0.1.16") })
        XCTAssertEqual(events, ["idle", "install 0.1.16", "verify"])
        XCTAssertEqual(result.version, "0.1.16")
    }

    func testRecoveryStartsExistingVersionWithoutDownloadingNewest() async throws {
        var starts = 0
        let result = try await DaemonServicePreparation.run(
            current: .init(ok: false), latest: "0.1.16", work: DaemonWorkState(),
            startInstalled: { starts += 1 }, install: { _ in XCTFail("Recovery changed the binary") },
            requireIdle: { _ in XCTFail("No update requested") }, health: { .init(ok: true, version: "0.1.15") })
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(result.version, "0.1.15")
    }

    func testConnectionFailureCannotBeMistakenForMissingInstallation() async throws {
        do {
            _ = try await DaemonServicePreparation.run(
                current: .init(ok: false), latest: "0.1.16", work: DaemonWorkState(),
                startInstalled: { throw URLError(.notConnectedToInternet) },
                install: { _ in XCTFail("Connection failure caused replacement") },
                requireIdle: { _ in }, health: { .init(ok: false) })
            XCTFail("Expected connection failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testConfirmedFirstInstallStillPreparesWorkspace() async throws {
        var installs: [String] = []
        let result = try await DaemonServicePreparation.run(
            current: .init(ok: false), latest: "0.1.16", work: DaemonWorkState(),
            startInstalled: { throw DaemonBootstrapError.notInstalled }, install: { installs.append($0) },
            requireIdle: { _ in XCTFail("There is no service to replace") }, health: { .init(ok: true, version: "0.1.16") })
        XCTAssertEqual(installs, ["0.1.16"])
        XCTAssertEqual(result.version, "0.1.16")
    }
}
