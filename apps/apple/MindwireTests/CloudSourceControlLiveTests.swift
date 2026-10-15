import SwiftUI
import UIKit
import XCTest
@testable import Mindwire

/// Opt-in device check. Uses the signed-in app and installed service, without
/// changing project files, publishing commits, or installing a different binary.
@MainActor
final class CloudSourceControlLiveTests: XCTestCase {
    func testManagedServiceStartupAndIdleRecovery() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["MINDWIRE_CLOUD_STARTUP_WORKSPACE"] else {
            throw XCTSkip("Opt in for an existing workspace on the signed-in phone")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Use the signed-in phone")
        #else
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdle }
        await OblienAuth.shared.refresh()
        XCTAssertTrue(OblienAuth.shared.authenticated)
        let handle = OblienCloud.client.workspace(id)
        let info = try await handle.get()
        XCTAssertTrue(info.isRunning)
        let service = CloudWorkspaceService(workspaceId: id)
        let token = await WorkspaceDaemonCredential.resolve(workspaceId: id, workspace: service)
        let http = DaemonHTTP(channel: ProxyDaemonChannel(workspaceId: id, daemonToken: token), agentType: "")
        let before: DaemonHealth = try await http.decode("GET", "/healthz", quiet: true)
        let originalProcesses = try await service.exec(["bash", "-lc", "pgrep -x mindwired | sort -n"])
        try await DaemonBootstrap.configureStartup(workspace: service, daemonToken: token)
        try await DaemonBootstrap.configureStartup(workspace: service, daemonToken: token)
        let after: DaemonHealth = try await http.decode("GET", "/healthz", quiet: true)
        XCTAssertTrue(after.ok)
        XCTAssertEqual(after.version, before.version)
        let sameProcesses = try await service.exec(["bash", "-lc", "pgrep -x mindwired | sort -n"])
        XCTAssertEqual(sameProcesses.stdout, originalProcesses.stdout, "Startup migration must leave active processes untouched")
        let persistedToken = await WorkspaceDaemonCredential.resolve(workspaceId: id, workspace: service)
        XCTAssertEqual(persistedToken, token)
        let workloads = try await handle.workloads.list()
        let registered = try XCTUnwrap(workloads.first { $0.id == CloudDaemonSupervisor.workloadID })
        XCTAssertEqual(registered.restartPolicy, .always)
        XCTAssertEqual(registered.enabled, true)
        XCTAssertEqual(workloads.filter { $0.id == CloudDaemonSupervisor.workloadID }.count, 1)
        print("CLOUD_STARTUP_CHECK registered one workload; existing daemon, version and credential preserved")

        guard env["MINDWIRE_CLOUD_STARTUP_RESTART_IDLE"] == "1" else { return }
        struct Lease: Decodable { let id: String; let pid: Int }
        let lease: Lease
        do { lease = try await http.decode("POST", "/service/update", json: [:], quiet: true) }
        catch let error as DaemonHTTPError where error.status == 409 {
            print("CLOUD_STARTUP_CHECK automatic restart test deferred: active work; startup is registered")
            return
        }
        do {
            // The server lease excludes new work. Verify this exact executable before SIGTERM.
            let stopped = try await service.exec(["bash", "-lc", """
            set -e
            [ "$(readlink /proc/\(lease.pid)/exe)" = "$HOME/.mindwire/mindwired" ]
            kill -TERM \(lease.pid)
            """])
            XCTAssertEqual(stopped.exitCode, 0)
            var restored: DaemonHealth?
            for _ in 0..<45 {
                if let health: DaemonHealth = try? await http.decode("GET", "/healthz", quiet: true), health.ok {
                    restored = health
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            XCTAssertEqual(restored?.ok, true, "The workload must restart without app-side startInstalled")
            XCTAssertEqual(restored?.version, before.version)
            let processes = try await service.exec(["bash", "-lc", "pgrep -x mindwired | sort -n"])
            let pids = processes.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            XCTAssertEqual(pids.count, 1)
            XCTAssertFalse(pids.contains(lease.pid))
            let metadata: WorkspaceMetadata = try await http.decode("GET", "/workspace", quiet: true)
            print("CLOUD_STARTUP_CHECK automatic restart passed; one daemon, projects=\(metadata.projects.count), version=\(restored?.version ?? "unknown")")
        } catch {
            _ = try? await http.run("DELETE", "/service/update/\(lease.id)", json: nil, quiet: true)
            throw error
        }
        #endif
    }

    func testSignedInSourceControlAndServiceRecovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let selected = environment["MINDWIRE_GIT_LIVE_WORKSPACES"], !selected.isEmpty else {
            throw XCTSkip("Opt in with selected cloud workspace IDs on the signed-in phone.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Use the signed-in phone.")
        #else
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled }
        await OblienAuth.shared.refresh()
        XCTAssertTrue(OblienAuth.shared.authenticated)
        for id in selected.split(separator: ",").map(String.init) {
            let live = try await OblienCloud.client.workspaces.get(id)
            XCTAssertTrue(live.isRunning)
            let workspace = Workspace(id: id, name: live.name ?? "Cloud workspace",
                runtime: .cloud(workspaceId: id), createdAt: isoNow())
            let service = CloudWorkspaceService(workspaceId: id)
            let literal = "quotes '\" `literal` $(literal)\nمرحبا 👋"
            let output = try await service.exec(["printf", "%s", literal])
            XCTAssertEqual(output.exitCode, 0)
            XCTAssertEqual(output.stdout.replacingOccurrences(of: "\r\n", with: "\n"), literal)
            let failed = try await service.exec(["/bin/sh", "-c", "exit 9"])
            XCTAssertEqual(failed.exitCode, 9, "An actual failure must not become a successful Git write")

            let suite = "live-cloud-git-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let stores = Stores(defaults: defaults)
            let coordinator = DaemonWorkCoordinator(defaults: defaults)
            let remote = WorkspaceRegistryClient(workspace: workspace, stores: stores, coordinator: coordinator)
            if environment["MINDWIRE_GIT_START_SERVICE"] == "1" {
                try await remote.startDaemon()
            }
            try await remote.prepare(allowInstall: false)
            let snapshot = try await remote.snapshot()
            stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
                resolveWorkspace: { $0 == workspace.id ? workspace : nil })
            try stores.workspaceData.apply(snapshot, workspaceId: workspace.id)
            for project in stores.projects(forWorkspaceId: workspace.id).prefix(1) {
                let model = GitModel(workspace: workspace, stores: stores, path: project.path)
                await model.load()
                XCTAssertNotNil(model.status)
                XCTAssertNil(model.error)
                XCTAssertFalse(model.loading)
                if let change = model.allChanges.first {
                    _ = try await model.diff(path: change.path, staged: change.isStaged)
                }
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let host = UIHostingController(rootView: SourceControlScreen(workspaceId: id, model: model)
                    .environment(\.stores, stores).tint(Palette.accent).preferredColorScheme(.dark))
                let window = UIWindow(windowScene: scene)
                window.rootViewController = host
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(700))
                let image = ChatFeedSnapshot.image(host)
                let attachment = XCTAttachment(image: image)
                attachment.name = "cloud-source-control-\(id)"; attachment.lifetime = .keepAlways; add(attachment)
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try image.pngData()?.write(to: directory.appendingPathComponent("MindwireSourceControlCheck.png"), options: .atomic)
                window.isHidden = true
                print("CLOUD_GIT_CHECK \(workspace.name): source control loaded; \(model.allChanges.count) changed files")
                await model.dispose()
            }
            // Check again after the foreground launcher has exited.
            remote.invalidateChecks()
            try await remote.prepare(allowInstall: false)
            XCTAssertEqual(coordinator.states[.init(workspaceId: id)]?.reachable, true)
            print("CLOUD_GIT_CHECK \(workspace.name): service stayed healthy; projects=\(snapshot.projects.count)")
            await remote.dispose()
        }
        #endif
    }
}
