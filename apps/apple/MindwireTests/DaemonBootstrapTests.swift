import XCTest
import UIKit
@testable import Mindwire

final class DaemonBootstrapTests: XCTestCase {
    func testRemoteDownloadProgressHandlesSplitPacketsAndUnknownLengths() {
        var reader = DaemonInstallOutput()
        XCTAssertTrue(reader.receive(Data("DAEMON_PROGRESS down".utf8)).isEmpty)
        let start = reader.receive(Data("loading\n\r    0.0%\r".utf8))
        XCTAssertEqual(start.count, 2)
        XCTAssertNil(start.first?.transferFraction)
        XCTAssertEqual(start.last?.transferFraction, 0)
        XCTAssertTrue(reader.receive(Data("\r################# 62".utf8)).isEmpty)
        let progress = reader.receive(Data(".5%\r".utf8))
        XCTAssertEqual(progress.first?.transferFraction, 0.625)
        XCTAssertTrue(reader.receive(Data("Warning: connection 50%\r # 120.0%\r -=O=-\r".utf8)).isEmpty)
        let completed = reader.receive(Data("######### 100.0%\rDAEMON_PROGRESS starting\n".utf8))
        XCTAssertEqual(completed.first?.transferFraction, 1)
        XCTAssertEqual(completed.last?.label, t("workspace.daemon.progress.starting"))
        XCTAssertTrue(reader.receive(Data("## 75.0%\rDAEMON_OK 0.1.22\n".utf8)).isEmpty)
    }

    @MainActor
    func testSignedInWorkspaceService() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MINDWIRE_INSTALL_CHECK"] == "1",
              let workspaceID = env["MINDWIRE_INSTALL_WORKSPACE"] else {
            throw XCTSkip("Opt in on a signed-in device for the selected workspace.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Use the signed-in phone.")
        #else
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
        await MindwireAuth.shared.refresh()
        XCTAssertTrue(MindwireAuth.shared.authenticated)
        let live = try await MindwireCloud.client.workspaces.get(workspaceID)
        XCTAssertTrue(live.isRunning)
        let fixture = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MindwireInstallFixture.json")
        let token = try await CloudDesktopProvider(workspaceId: workspaceID).gatewayToken()
        try JSONSerialization.data(withJSONObject: ["workspaceId": workspaceID, "token": token,
            "baseURL": MindwireCloud.client.config.runtimeURL.absoluteString])
            .write(to: fixture, options: [.atomic, .completeFileProtection])
        print("INSTALL_CHECK scoped diagnostic fixture saved privately")
        if env["MINDWIRE_INSTALL_VERIFY"] == "1" {
            defer { try? FileManager.default.removeItem(at: fixture) }
            let workspace = Workspace(id: workspaceID, name: live.name ?? "Install check",
                runtime: .cloud(workspaceId: workspaceID), createdAt: isoNow())
            let client = WorkspaceRegistryClient(workspace: workspace, stores: Stores())
            try await client.updateDaemon()
            try await client.prepare(allowInstall: false)
            let first = try await client.snapshot()
            try await Task.sleep(for: .seconds(5))
            client.invalidateChecks()
            try await client.prepare(allowInstall: false)
            let second = try await client.snapshot()
            XCTAssertEqual(first.workspaceId, second.workspaceId)
            print("INSTALL_CHECK installed service stayed healthy after the launch request ended")
        }
        #endif
    }

    func testDestinationUsesWorkspaceOSAndArchitectureEvenWhenExecStripsNewlines() throws {
        for (os, machine, platform, arch) in [
            ("Darwin", "arm64", "darwin", "arm64"),
            ("Darwin", "x86_64", "darwin", "amd64"),
            ("Linux", "aarch64", "linux", "arm64"),
            ("Linux", "x86_64", "linux", "amd64")
        ] {
            let destination = try DaemonBootstrap.destination(from:
                "runtime output<<OS:\(os)>><<ARCH:\(machine)>><<DIR:/Users/workspace owner/.mindwire>>done")
            XCTAssertEqual(destination.platform.rawValue, platform)
            XCTAssertEqual(destination.arch, arch)
            XCTAssertEqual(destination.directory, "/Users/workspace owner/.mindwire")
        }
    }

    func testUnsupportedOrUnreadableDestinationFailsBeforeDownloadingOrReplacingDaemon() {
        for output in [
            "<<OS:FreeBSD>><<ARCH:x86_64>><<DIR:/workspace/.mindwire>>",
            "<<OS:Linux>><<ARCH:riscv64>><<DIR:/workspace/.mindwire>>",
            "<<ARCH:arm64>><<DIR:/workspace/.mindwire>>",
            "<<OS:Darwin>><<ARCH:arm64>><<DIR:relative/.mindwire>>",
            "<<OS:Darwin>><<ARCH:arm64>><<DIR:/workspace/\n.mindwire>>",
            "runtime unavailable"
        ] {
            XCTAssertThrowsError(try DaemonBootstrap.destination(from: output))
        }
    }
}
