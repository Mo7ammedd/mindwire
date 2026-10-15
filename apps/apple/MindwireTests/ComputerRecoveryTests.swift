import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class ComputerRecoveryTests: XCTestCase {
    private struct Fixture {
        let stores: Stores
        let connection: Connection
        let workspace: Workspace
        let result: ComputerPairingService.Result
    }

    private func fixture() throws -> Fixture {
        let id = UUID().uuidString
        let suite = "computer-recovery-" + id
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let stores = Stores(defaults: defaults)
        let computer = PairedComputer(computerId: id, registryId: "registry-" + id, deviceId: "phone-" + id,
            fingerprint: "SHA256:" + String(repeating: "a", count: 43),
            routes: [.init(kind: "ssh", host: "127.0.0.1", port: 1)],
            keyRef: "recovery-key-" + id, tokenRef: "recovery-token-" + id)
        XCTAssertTrue(Keychain.set("fixture-key", for: computer.keyRef))
        XCTAssertTrue(Keychain.set("fixture-token", for: computer.tokenRef))
        let host = ComputerHost(hostname: "Mac", os: "darwin", arch: "arm64", home: "/fixture", directory: "/fixture", pid: 1)
        let result = ComputerPairingService.Result(computer: computer, host: host,
            health: DaemonHealth(ok: true, agent: nil, version: "fixture", workspaceMetadataVersion: 1))
        let connection = stores.savePairedComputer(result, name: "My Mac")
        let workspace = try XCTUnwrap(stores.workspaces(forServerId: connection.id).first)
        addTeardownBlock { @MainActor in
            defaults.removePersistentDomain(forName: suite)
            Keychain.delete(computer.keyRef); Keychain.delete(computer.tokenRef)
            DaemonWorkCoordinator.shared.forget(workspaceId: workspace.id)
        }
        return Fixture(stores: stores, connection: connection, workspace: workspace, result: result)
    }

    func testOfflineWorkspaceRemovalOnlyForgetsThisPhonesConnectionAndCache() async throws {
        let f = try fixture()
        let project = f.stores.createProject(.init(name: "App", workspaceId: f.workspace.id, path: "/fixture/app"))
        let agent = f.stores.createAgent(.init(name: "Codex", agentType: .codex, workspaceId: f.workspace.id))
        let chat = f.stores.createChat(agentId: agent.id, projectId: project.id)
        let other = f.stores.createWorkspace(name: "Keep", runtime: .server(serverId: "another-server"))
        var calls = 0
        let repository = WorkspaceRepository(stores: f.stores, adapters: [LocalWorkspaceAdapter(stores: f.stores)], resumeComputer: { _, _ in
            calls += 1
            throw ComputerConnectionError.unreachable
        })
        let key = DaemonWorkKey(workspaceId: f.workspace.id)
        DaemonWorkCoordinator.shared.recordFailure(ComputerConnectionError.unreachable, for: key,
            revision: DaemonWorkCoordinator.shared.probeRevision(key))

        try await repository.delete(f.workspace.id)

        XCTAssertEqual(calls, 0, "Local removal must not contact the offline computer")
        XCTAssertNil(repository.get(f.workspace.id))
        XCTAssertNil(f.stores.connections.get(f.connection.id))
        XCTAssertNil(f.stores.projects.get(project.id))
        XCTAssertNil(f.stores.agents.get(agent.id))
        XCTAssertNil(f.stores.chats.get(chat.id))
        XCTAssertNil(Keychain.get(f.result.computer.keyRef))
        XCTAssertNil(Keychain.get(f.result.computer.tokenRef))
        XCTAssertNil(DaemonWorkCoordinator.shared.states[key])
        XCTAssertNotNil(repository.get(other.id))
        repository.forgetConnection(f.connection.id) // repeated removal is harmless
        XCTAssertNotNil(repository.get(other.id))
    }

    func testRepeatedRecoveryJoinsOneAttemptAndClearsOfflineStateWithoutDuplicatingWorkspace() async throws {
        let f = try fixture()
        var calls = 0
        var computer = f.result.computer
        computer.routes = [.init(kind: "ssh", host: "127.0.0.1", port: 2)]
        let result = ComputerPairingService.Result(computer: computer, host: f.result.host, health: f.result.health)
        let repository = WorkspaceRepository(stores: f.stores, adapters: [LocalWorkspaceAdapter(stores: f.stores)], resumeComputer: { _, onStatus in
            calls += 1
            onStatus("Checking your saved addresses…")
            try await Task.sleep(for: .milliseconds(40))
            return result
        })
        let key = DaemonWorkKey(workspaceId: f.workspace.id)
        DaemonWorkCoordinator.shared.recordFailure(ComputerConnectionError.unreachable, for: key,
            revision: DaemonWorkCoordinator.shared.probeRevision(key))
        let connections = try await withThrowingTaskGroup(of: Connection.self, returning: [Connection].self) { group in
            for _ in 0..<8 { group.addTask { try await repository.reconnectComputer(f.connection.id) } }
            var values: [Connection] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(Set(connections.map(\.id)), [f.connection.id])
        XCTAssertEqual(f.stores.connections.list().count, 1)
        XCTAssertEqual(repository.all.map(\.id), [f.workspace.id])
        XCTAssertTrue(repository.reconnectingComputers.isEmpty)
        XCTAssertEqual(DaemonWorkCoordinator.shared.states[key]?.reachable, true)
        XCTAssertNil(DaemonWorkCoordinator.shared.states[key]?.connectionError)
    }

    func testFailedRecoveryIsSharedAndCanBeRetried() async throws {
        let f = try fixture()
        var calls = 0
        let repository = WorkspaceRepository(stores: f.stores, adapters: [LocalWorkspaceAdapter(stores: f.stores)], resumeComputer: { _, _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(40))
            throw ComputerConnectionError.unreachable
        })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try? await repository.reconnectComputer(f.connection.id) } }
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(repository.reconnectingComputers.isEmpty)
        XCTAssertEqual(f.stores.connections.get(f.connection.id), f.connection)
        _ = try? await repository.reconnectComputer(f.connection.id)
        XCTAssertEqual(calls, 2, "Failure must not leave a stuck shared attempt")
    }

    func testForgettingWhileRecoveryFinishesCannotRestoreRemovedComputer() async throws {
        let f = try fixture()
        var finish: CheckedContinuation<ComputerPairingService.Result, Never>?
        let repository = WorkspaceRepository(stores: f.stores, adapters: [LocalWorkspaceAdapter(stores: f.stores)], resumeComputer: { _, _ in
            await withCheckedContinuation { finish = $0 }
        })
        let pending = Task { try await repository.reconnectComputer(f.connection.id) }
        while finish == nil { await Task.yield() }
        repository.forgetConnection(f.connection.id)
        finish?.resume(returning: f.result)
        do { _ = try await pending.value; XCTFail("Forgotten recovery was accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(repository.all.isEmpty)
        XCTAssertTrue(f.stores.connections.list().isEmpty)
        XCTAssertTrue(repository.reconnectingComputers.isEmpty)
    }

    func testRetryReportsProgressAndExplicitCancellationDiscardsLateCompletion() async throws {
        let f = try fixture()
        var finish: CheckedContinuation<ComputerPairingService.Result, Never>?
        var report: (@MainActor @Sendable (String) -> Void)?
        let repository = WorkspaceRepository(stores: f.stores, adapters: [LocalWorkspaceAdapter(stores: f.stores)], resumeComputer: { _, onStatus in
            report = onStatus
            onStatus("Retrying secure connection (2 of 3)…")
            return await withCheckedContinuation { finish = $0 }
        })
        let pending = Task { try await repository.reconnectComputer(f.connection.id) }
        while finish == nil { await Task.yield() }
        XCTAssertEqual(repository.computerReconnectMessages[f.connection.id], "Retrying secure connection (2 of 3)…")
        XCTAssertTrue(repository.reconnectingComputers.contains(f.connection.id))

        repository.cancelComputerReconnect(f.connection.id)
        XCTAssertFalse(repository.reconnectingComputers.contains(f.connection.id))
        report?("Stale attempt")
        XCTAssertNil(repository.computerReconnectMessages[f.connection.id])
        finish?.resume(returning: f.result)
        do { _ = try await pending.value; XCTFail("Cancelled recovery completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(f.stores.connections.get(f.connection.id), f.connection)
    }

    func testRepairKeepsScanActionVisibleWithoutRetryingOrDismissingOnOpening() async throws {
        let f = try fixture()
        var attempts = 0
        let repository = WorkspaceRepository(stores: f.stores, adapters: [LocalWorkspaceAdapter(stores: f.stores)], resumeComputer: { _, onStatus in
            attempts += 1
            onStatus("Checking your saved addresses…")
            throw ComputerConnectionError.internetAddressUnavailable
        })
        let host = UIHostingController(rootView: ComputerRecoverySheet(serverId: f.connection.id, repository: repository)
            .environment(\.stores, f.stores).labelIconToTitleSpacing(Spacing.md)
            .preferredColorScheme(.dark).tint(Palette.accent))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        let image = ChatFeedSnapshot.image(host)
        let text = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Repair Connection"), text)
        XCTAssertTrue(text.contains("Scan Connection Code"), text)
        XCTAssertTrue(text.contains("mindwire connect pair"), text)
        XCTAssertTrue(text.contains("Retry Saved Connection"), text)
        XCTAssertEqual(attempts, 0, "Opening Repair must not start a retry that dismisses the sheet before scanning")
        XCTAssertFalse(repository.reconnectingComputers.contains(f.connection.id))
        let attachment = XCTAttachment(image: image)
        attachment.name = "mindwire-computer-recovery-dns"; attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-computer-recovery-dns.png"))
    }

    func testComputerPageShowsRecoveryControlsWithTechnicalDetailsCollapsed() async throws {
        let f = try fixture()
        var attempts = 0
        let repository = WorkspaceRepository(stores: f.stores, adapters: [LocalWorkspaceAdapter(stores: f.stores)], resumeComputer: { _, _ in
            attempts += 1
            return f.result
        })
        repository.computerRecovery.succeeded(f.connection.id)
        let host = UIHostingController(rootView: NavigationStack {
            ServerDetailScreen(serverId: f.connection.id, repository: repository)
        }.environment(\.stores, f.stores).labelIconToTitleSpacing(Spacing.md)
            .preferredColorScheme(.dark).tint(Palette.accent))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        let image = ChatFeedSnapshot.image(host)
        let text = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(text.contains("Connected"), text)
        XCTAssertTrue(text.contains("Reconnect"), text)
        XCTAssertTrue(text.contains("Repair"), text)
        XCTAssertFalse(text.contains("Test Connection"), text)
        XCTAssertFalse(text.contains("Internet tunnel"), text)
        XCTAssertEqual(attempts, 0, "Navigating to a healthy computer must use its cached status")
        let attachment = XCTAttachment(image: image)
        attachment.name = "mindwire-computer-recovery-controls"; attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-computer-recovery-controls.png"))
    }

    func testAQueuedWorkspaceReadCannotRecreateForgottenLocalMetadata() async throws {
        let f = try fixture()
        let remote = WorkspaceRemoteFixture()
        var madeRemote = 0
        let data = WorkspaceDataRepository(stores: f.stores, makeRemote: { _ in madeRemote += 1; return remote },
            resolveWorkspace: { f.stores.workspaces.get($0) })
        data.forget(f.workspace.id)
        f.stores.deleteServer(f.connection.id)
        await data.refresh(f.workspace) // a previously captured inventory
        XCTAssertEqual(madeRemote, 0)
        XCTAssertTrue(f.stores.workspaces.list().isEmpty)
        XCTAssertTrue(f.stores.projects.list().isEmpty)
    }
}
