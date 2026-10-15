import XCTest
import OblienKit
@testable import Mindwire

@MainActor
final class DaemonStartupTests: XCTestCase {
    private let destination = DaemonBootstrap.Destination(platform: .linux, arch: "amd64", directory: "/home/me/.mindwire", user: "me")

    private func workload(status: String = "running") -> Workload {
        var value = Workload(id: CloudDaemonSupervisor.workloadID, name: "Mindwire service", status: status,
                             cmd: ["/bin/bash", destination.directory + "/service-runner.sh"], restartPolicy: .always)
        value.maxRestarts = 0
        value.enabled = true
        return value
    }

    func testWorkloadRegistrationKeepsSecretsOnTheWorkspaceAndUsesStableOwnership() throws {
        let params = CloudDaemonSupervisor.parameters(destination: destination)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, "mindwire-service")
        XCTAssertEqual(body["cmd"] as? [String], ["/bin/bash", "/home/me/.mindwire/service-runner.sh"])
        XCTAssertEqual(body["restart_policy"] as? String, "always")
        XCTAssertEqual(body["max_restarts"] as? Int, 0)
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertEqual(body["user"] as? String, "me")
        XCTAssertNil(body["env"], "The workload must read the existing private credential file")
        XCTAssertNil(body["max_log_size_mb"], "Use platform defaults without requiring the optional log-controls capability")
        XCTAssertNil(body["log_retention_hours"])
    }

    func testHealthyManagedWorkloadDoesNotRestartOrRewriteOnRepeatedChecks() async throws {
        let running = workload()
        for _ in 0..<3 {
            try await CloudDaemonSupervisor.ensure(destination: destination, get: { running },
                create: { _ in XCTFail("Duplicate workload"); return running },
                patch: { _ in XCTFail("Already configured") }, start: { XCTFail("Already running") })
        }
    }

    func testExistingPolicyIsRepairedWithoutInterruptingTheProcess() async throws {
        var running = workload()
        running.restartPolicy = .never
        running.maxRestarts = 3
        var repairs = 0
        try await CloudDaemonSupervisor.ensure(destination: destination, get: { running },
            create: { _ in XCTFail("Already exists"); return running },
            patch: { params in
                repairs += 1
                XCTAssertEqual(params.restartPolicy, .always)
                XCTAssertEqual(params.maxRestarts, 0)
                XCTAssertNil(params.cmd, "A policy repair must not replace the running command")
            }, start: { XCTFail("Running workload must not restart") })
        XCTAssertEqual(repairs, 1)
    }

    func testStoppedWorkloadIsStartedWithoutCreatingAnother() async throws {
        let stopped = workload(status: "stopped")
        var starts = 0
        try await CloudDaemonSupervisor.ensure(destination: destination, get: { stopped },
            create: { _ in XCTFail("Duplicate workload"); return stopped },
            patch: { _ in XCTFail("Policy already correct") }, start: { starts += 1 })
        XCTAssertEqual(starts, 1)
    }

    func testConcurrentCreateOrLostResponseReusesTheSameWorkload() async throws {
        for status in [409, 504] {
            var reads = 0, creates = 0
            let running = workload()
            try await CloudDaemonSupervisor.ensure(destination: destination, get: {
                reads += 1
                if reads == 1 { throw self.apiError(404) }
                return running
            }, create: { params in
                creates += 1
                XCTAssertEqual(params.id, running.id)
                throw self.apiError(status)
            }, patch: { _ in XCTFail("No duplicate configuration") }, start: { XCTFail("No duplicate start") })
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(creates, 1)
        }
    }

    func testForeignWorkloadWithReservedIDIsNeverModified() async throws {
        var foreign = workload()
        foreign.cmd = ["node", "my-server.js"]
        do {
            try await CloudDaemonSupervisor.ensure(destination: destination, get: { foreign },
                create: { _ in XCTFail("Must not create"); return foreign },
                patch: { _ in XCTFail("Must not change someone else's workload") },
                start: { XCTFail("Must not start someone else's workload") })
            XCTFail("Expected ownership error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("different workload")) }
    }

    func testCompetingStartIsAcceptedOnlyAfterVerifyingTheOwnedWorkload() async throws {
        var reads = 0, starts = 0
        try await CloudDaemonSupervisor.ensure(destination: destination, get: {
            reads += 1
            return self.workload(status: reads == 1 ? "stopped" : "running")
        }, create: { _ in XCTFail("Already registered"); return self.workload() },
        patch: { _ in XCTFail("Already configured") }, start: {
            starts += 1
            throw self.apiError(409)
        })
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(reads, 2)
    }

    func testFailedLookupIsNotTreatedAsMissingWorkload() async throws {
        for status in [401, 403, 503] {
            do {
                try await CloudDaemonSupervisor.ensure(destination: destination, get: { throw self.apiError(status) },
                    create: { _ in XCTFail("Unverified existence"); return self.workload() },
                    patch: { _ in XCTFail("Unverified existence") }, start: { XCTFail("Unverified existence") })
                XCTFail("Expected lookup error")
            } catch { XCTAssertEqual((error as? OblienError)?.status, status) }
        }
    }

    func testRecoveryOnlyHandlesServiceConnectionFailures() {
        XCTAssertTrue(DaemonServiceRecovery.canStart(after: DaemonHTTPError(status: 502, message: "connection refused")))
        XCTAssertTrue(DaemonServiceRecovery.canStart(after: URLError(.cannotConnectToHost)))
        for error in [CancellationError(), URLError(.cancelled), URLError(.notConnectedToInternet),
                      DaemonHTTPError(status: 401, message: "Sign in"), DaemonHTTPError(status: 403, message: "Denied"),
                      DaemonHTTPError(status: 404, message: "Missing")] as [Error] {
            XCTAssertFalse(DaemonServiceRecovery.canStart(after: error))
        }
    }

    func testStartupMigrationIsSharedAndPersistsWithoutNavigationChecks() async throws {
        let name = "MindwireTests.startup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let coordinator = DaemonWorkCoordinator(defaults: defaults)
        let key = DaemonWorkKey(workspaceId: UUID().uuidString)
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        coordinator.configureStartupIfNeeded(key) {
            calls += 1
            await withCheckedContinuation { release = $0 }
        }
        for _ in 0..<100 where release == nil { await Task.yield() }
        XCTAssertNotNil(release)
        coordinator.configureStartupIfNeeded(key) { XCTFail("Concurrent registration duplicated") }
        release?.resume()
        for _ in 0..<100 { await Task.yield() }
        let reopened = DaemonWorkCoordinator(defaults: defaults)
        reopened.configureStartupIfNeeded(key) { XCTFail("App launch re-registered startup") }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1)
    }

    func testFailedRecoveryBacksOffUntilExplicitRefreshOrVerifiedHealth() throws {
        let name = "MindwireTests.recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let coordinator = DaemonWorkCoordinator(defaults: defaults)
        let key = DaemonWorkKey(workspaceId: "recovery")
        coordinator.serviceRecoveryFailed(key)
        XCTAssertFalse(coordinator.canRecoverService(key))
        coordinator.invalidateChecks(key)
        XCTAssertTrue(coordinator.canRecoverService(key))
        coordinator.serviceRecoveryFailed(key)
        coordinator.recordHealth(.init(ok: true, version: "0.1.38"), for: key)
        XCTAssertTrue(coordinator.canRecoverService(key), "A new outage after successful recovery gets its own attempt")
    }

    /// Emits the production shell scripts for the host-side process/lock/crash tests.
    /// These execute in a disposable directory and never register a service on this Mac.
    func testEmitScriptsForHostLifecycleChecks() throws {
        guard let path = ProcessInfo.processInfo.environment["MINDWIRE_STARTUP_SCRIPTS"] else {
            throw XCTSkip("Set MINDWIRE_STARTUP_SCRIPTS for host-side lifecycle checks")
        }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("runtime owner' $ literal/.mindwire").path
        let platform: DaemonRelease.Platform = ProcessInfo.processInfo.environment["MINDWIRE_STARTUP_OS"] == "Linux" ? .linux : .darwin
        let dest = DaemonBootstrap.Destination(platform: platform, arch: "arm64", directory: directory)
        let port = Int(ProcessInfo.processInfo.environment["MINDWIRE_STARTUP_PORT"] ?? "") ?? 29879
        let scripts: [String: String] = [
            "configure.sh": DaemonStartup.configurationScript(destination: dest, daemonToken: "fixture-token", requireInstalled: false, port: port),
            "configure-empty.sh": DaemonStartup.configurationScript(destination: dest, daemonToken: "", requireInstalled: false, port: port),
            "configure-existing.sh": DaemonStartup.configurationScript(destination: dest, daemonToken: "fixture-token", requireInstalled: true, port: port),
            "native.sh": DaemonStartup.nativeRegistrationScript(destination: dest),
            "background.sh": DaemonStartup.nativeRegistrationScript(destination: dest, nativeServices: false),
            "start.sh": DaemonBootstrap.startScript(destination: dest, daemonToken: "fixture-token", port: port, supervised: true),
            "install.sh": DaemonBootstrap.installScript(destination: dest, source: .upload(path: root.appendingPathComponent("binary.b64").path),
                target: "0.1.39", daemonToken: "fixture-token", requireUpdateLease: true, port: port, supervised: true)
        ]
        for (name, source) in scripts { try source.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let info: [String: Any] = ["directory": directory, "port": port]
        try JSONSerialization.data(withJSONObject: info).write(to: root.appendingPathComponent("fixture.json"))
    }

    private func apiError(_ status: Int) -> OblienError {
        .init(kind: .server, status: status, code: nil, message: "Fixture error", details: nil)
    }

    func testExportExistingCloudServiceStartup() throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["MINDWIRE_CLOUD_STARTUP_SCRIPTS"],
              let directory = env["MINDWIRE_CLOUD_STARTUP_DIRECTORY"] else {
            throw XCTSkip("Opt in to export the existing cloud service startup plan")
        }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = DaemonBootstrap.Destination(platform: .linux, arch: "amd64", directory: directory,
                                              user: env["MINDWIRE_CLOUD_STARTUP_USER"])
        // Credentials stay on the workspace. These scripts require the existing executable.
        let configure = DaemonStartup.configurationScript(destination: dest, daemonToken: "", requireInstalled: true)
        let start = DaemonBootstrap.startScript(destination: dest, daemonToken: "", supervised: true)
        try configure.write(to: root.appendingPathComponent("configure-existing.sh"), atomically: true, encoding: .utf8)
        try start.write(to: root.appendingPathComponent("start.sh"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(CloudDaemonSupervisor.parameters(destination: dest))
            .write(to: root.appendingPathComponent("workload.json"))
    }
}
