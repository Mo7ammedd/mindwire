import XCTest
@testable import Mindwire

final class DockerWorkspaceTests: XCTestCase {
    private let sandbox = ServerSandbox(id: String(repeating: "a", count: 32), version: "0.1.15")
    private let spec = WorkspaceSpec(cpus: 2, memoryMb: 2048, diskMb: 0, persistent: true)

    func testCreationIsRetryableAndExecStaysInTheOwnedContainer() async throws {
        let fixture = DockerFixture(sandbox: sandbox)
        let host = DockerWorkspaceHost { try await fixture.execute($0, timeout: $1) }
        try await host.prepare(sandbox, displayName: "My 'sandbox'", spec: spec)
        try await host.prepare(sandbox, displayName: "My 'sandbox'", spec: spec)
        let result = try await host.exec(sandbox, ["git", "-C", "/home/node/a b", "status"])
        XCTAssertEqual(result.stdout, "inside container")
        let calls = await fixture.calls
        let creates = calls.filter { $0.starts(with: ["docker", "run"]) }
        XCTAssertEqual(creates.count, 1)
        let create = try XCTUnwrap(creates.first)
        XCTAssertTrue(create.contains("127.0.0.1::8790"))
        XCTAssertTrue(create.contains("type=volume,source=\(sandbox.volume),target=/home/node"))
        XCTAssertFalse(create.contains("--privileged"))
        XCTAssertFalse(create.joined().contains("docker.sock"))
        XCTAssertFalse(create.contains(where: { $0.hasPrefix("DAEMON_TOKEN=") }))
        XCTAssertTrue(create.contains("MINDWIRE_ISOLATION=container"))
        XCTAssertEqual(calls.last, ["docker", "exec", "--workdir", "/home/node", "owned-container-id",
                                    "git", "-C", "/home/node/a b", "status"])
    }

    func testStoppedContainerIsNotStartedByReadsOrTerminalNavigation() async throws {
        let fixture = DockerFixture(sandbox: sandbox, status: "exited")
        let host = DockerWorkspaceHost { try await fixture.execute($0, timeout: $1) }
        let service = DockerWorkspaceService(host: host, sandbox: sandbox)
        let status = try await service.status()
        XCTAssertEqual(status.power, .stopped)
        let resources = try await service.getResources()
        XCTAssertEqual(resources.cpus, 2)
        XCTAssertEqual(resources.memoryMb, 2048)
        for action in 0..<3 {
            do {
                if action == 0 { _ = try await host.port(sandbox) }
                if action == 1 { _ = try await host.exec(sandbox, ["touch", "/host-must-stay-unchanged"]) }
                if action == 2 { _ = try await host.terminalCommand(sandbox, workdir: "/project") }
                XCTFail("A stopped workspace must require an explicit Start")
            } catch WorkspaceRegistryError.workspaceNotRunning(.stopped) {}
        }
        let calls = await fixture.calls
        XCTAssertTrue(calls.allSatisfy { $0.starts(with: ["docker", "inspect"]) })
        try await host.power(sandbox, .start)
        let command = try await host.terminalCommand(sandbox, workdir: "/home/node/a ' b")
        XCTAssertEqual(DockerFixture.dockerArguments(command), ["docker", "exec", "-it", "--workdir", "/home/node/a ' b", "owned-container-id", "bash", "-l"])
    }

    func testDeletionChecksBothOwnersBeforeRemovingAnything() async throws {
        let fixture = DockerFixture(sandbox: sandbox, status: "running")
        let host = DockerWorkspaceHost { try await fixture.execute($0, timeout: $1) }
        await fixture.setOwner("another-workspace")
        do { try await host.remove(sandbox); XCTFail("Foreign container") }
        catch DockerWorkspaceError.ownership {}
        await fixture.setOwner(sandbox.id)
        await fixture.setVolumeOwner("another-workspace")
        do { try await host.remove(sandbox); XCTFail("Foreign volume") }
        catch DockerWorkspaceError.ownership {}
        let before = await fixture.calls
        XCTAssertFalse(before.contains { $0.contains("rm") })
        await fixture.setVolumeOwner(sandbox.id)
        try await host.remove(sandbox)
        let after = await fixture.calls
        XCTAssertTrue(after.contains(["docker", "rm", "-f", "owned-container-id"]))
        XCTAssertTrue(after.contains(["docker", "volume", "rm", sandbox.volume]))
        let absent = try await host.inspect(sandbox)
        XCTAssertNil(absent)
    }

    func testRejectsPublicPublicationAndInvalidIdentity() async throws {
        let fixture = DockerFixture(sandbox: sandbox, status: "running")
        await fixture.setBindHost("0.0.0.0")
        let host = DockerWorkspaceHost { try await fixture.execute($0, timeout: $1) }
        do { _ = try await host.port(sandbox); XCTFail("Must use a private host publication") }
        catch DockerWorkspaceError.notPublished {}
        let count = await fixture.calls.count
        let invalid = ServerSandbox(id: "../foreign", version: "latest")
        do { _ = try await host.exec(invalid, ["true"]); XCTFail("Invalid persisted identity") }
        catch DockerWorkspaceError.invalid {}
        let after = await fixture.calls.count
        XCTAssertEqual(after, count)
    }

    func testRuntimeAndImageReleaseSelectionPreserveCompatibility() throws {
        let runtime = AgentRuntime.container(serverId: "ssh-host", sandbox: sandbox)
        let restored = try JSONDecoder().decode(AgentRuntime.self, from: JSONEncoder().encode(runtime))
        XCTAssertEqual(restored, runtime)
        XCTAssertEqual(restored.serverId, "ssh-host")
        XCTAssertTrue(restored.isServer)
        XCTAssertFalse(restored.isCloud)
        let legacy = try JSONDecoder().decode(AgentRuntime.self, from: Data(#"{"kind":"server","serverId":"ssh-host"}"#.utf8))
        XCTAssertNil(legacy.sandbox)
        XCTAssertEqual(RuntimeImageRelease.select(["latest", "0.1", "0.1.14", "0.1.15", "0.1.17", "0.1.16-beta.1"], target: "0.1.16"), "0.1.15")
        XCTAssertEqual(RuntimeImageRelease.select(["0.1.15", "0.1.16"], target: "0.1.16"), "0.1.16")
        XCTAssertNil(RuntimeImageRelease.select(["0.1.14", "0.1.17"], target: "0.1.16"))
    }
}

private actor DockerFixture {
    let sandbox: ServerSandbox
    private var status: String?
    private var owner: String
    private var volumeOwner: String?
    private var bindHost = "127.0.0.1"
    private(set) var calls: [[String]] = []
    init(sandbox: ServerSandbox, status: String? = nil) {
        self.sandbox = sandbox; self.status = status; self.owner = sandbox.id
        self.volumeOwner = status == nil ? nil : sandbox.id
    }
    func setOwner(_ value: String) { owner = value }
    func setVolumeOwner(_ value: String) { volumeOwner = value }
    func setBindHost(_ value: String) { bindHost = value }

    static func dockerArguments(_ arguments: [String]) -> [String] {
        guard let hostIndex = arguments.firstIndex(of: "--host") else { return arguments }
        return ["docker"] + arguments.dropFirst(hostIndex + 2)
    }

    func execute(_ rawArguments: [String], timeout: Int64) throws -> ExecResult {
        func ok(_ body: String = "") -> ExecResult { .init(exitCode: 0, stdout: body, stderr: "") }
        func absent(_ kind: String) -> ExecResult { .init(exitCode: 1, stdout: "", stderr: "Error: No such \(kind)") }
        if rawArguments == ["bash", "-lc", DockerEngine.probeScript] {
            return ok("MINDWIRE_DOCKER_MODE=direct\nMINDWIRE_DOCKER_PATH=/usr/bin/docker\nMINDWIRE_DOCKER_ENDPOINT=unix:///var/run/docker.sock\n")
        }
        let arguments = Self.dockerArguments(rawArguments)
        calls.append(arguments)
        if arguments.starts(with: ["docker", "info"]) { return ok("28.0.0") }
        if arguments.starts(with: ["docker", "inspect"]) {
            guard let status else { return absent("container") }
            return ok(String(decoding: try JSONSerialization.data(withJSONObject: [
                "id": "owned-container-id", "owner": owner, "displayName": "Sandbox", "image": sandbox.image,
                "status": status, "created": "2026-09-23T00:00:00Z", "ports": [["HostIp": bindHost, "HostPort": "32100"]],
                "memory": 2_147_483_648, "nanoCPUs": 2_000_000_000
            ]), as: UTF8.self))
        }
        if arguments.starts(with: ["docker", "image", "inspect"]) { return ok("image-id") }
        if arguments.starts(with: ["docker", "volume", "inspect"]) {
            return volumeOwner.map { ok($0) } ?? absent("volume")
        }
        if arguments.starts(with: ["docker", "volume", "create"]) { volumeOwner = sandbox.id; return ok(sandbox.volume) }
        if arguments.starts(with: ["docker", "run"]) { status = "running"; return ok("owned-container-id") }
        if arguments.starts(with: ["docker", "start"]) { status = "running"; return ok() }
        if arguments.starts(with: ["docker", "exec"]) { return ok("inside container") }
        if arguments.starts(with: ["docker", "rm"]) { status = nil; return ok() }
        if arguments.starts(with: ["docker", "volume", "rm"]) { volumeOwner = nil; return ok() }
        throw BackendError.message("Unexpected fixture operation: \(arguments.prefix(3))")
    }
}

@MainActor
final class DockerWorkspaceInventoryTests: XCTestCase {
    private let sandbox = ServerSandbox(id: String(repeating: "b", count: 32), version: "0.1.15")
    private func stores() throws -> Stores {
        let suite = "docker-inventory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        stores.connections.save(.ssh(.init(id: "host", name: "Server", type: .ssh, host: "test.invalid", port: 22,
            username: "test", auth: .agent, createdAt: isoNow())))
        return stores
    }
    private func snapshot() throws -> DockerWorkspaceHost.Snapshot {
        try JSONDecoder().decode(DockerWorkspaceHost.Snapshot.self, from: JSONSerialization.data(withJSONObject: [
            "id": "container-id", "owner": sandbox.id, "displayName": "Remote sandbox", "image": sandbox.image,
            "status": "exited", "created": "2026-09-23T00:00:00Z", "memory": 2_147_483_648, "nanoCPUs": 2_000_000_000
        ]))
    }

    func testServerInventoryRecoversCacheAndOnlyConfirmedDeletionRemovesIt() async throws {
        let stores = try stores()
        let direct = stores.createWorkspace(name: "Host", runtime: .server(serverId: "host"))
        var listed = [try snapshot()]
        var offline = false
        let adapter = DockerWorkspaceAdapter(stores: stores, inventory: { _ in
            if offline { throw URLError(.networkConnectionLost) }
            return listed
        })
        try await adapter.refresh()
        XCTAssertEqual(adapter.current().map(\.id), [sandbox.id])
        XCTAssertEqual(adapter.current().first?.name, "Remote sandbox")
        XCTAssertEqual(LocalWorkspaceAdapter(stores: stores).current().map(\.id), [direct.id])
        offline = true
        do { try await adapter.refresh(); XCTFail("Unreachable inventory") } catch {}
        XCTAssertEqual(adapter.current().map(\.id), [sandbox.id])
        let unconfirmed = await adapter.confirmsDeletion(sandbox.id)
        XCTAssertFalse(unconfirmed)
        offline = false; listed = []
        try await adapter.refresh()
        XCTAssertTrue(adapter.current().isEmpty)
        XCTAssertNotNil(stores.workspaces.get(direct.id))
        let confirmed = await adapter.confirmsDeletion(sandbox.id)
        XCTAssertTrue(confirmed)
    }

    func testStaleInventoryCannotUndoAdoptionOrResurrectDeletion() async throws {
        let stores = try stores()
        var resume: CheckedContinuation<[DockerWorkspaceHost.Snapshot], Never>?
        let began = expectation(description: "Inventory is pending")
        began.expectedFulfillmentCount = 1
        var calls = 0
        let adapter = DockerWorkspaceAdapter(stores: stores, inventory: { _ in
            calls += 1
            return await withCheckedContinuation { resume = $0; if calls == 1 { began.fulfill() } }
        }, remove: { _, _ in })
        let first = Task { try await adapter.refresh() }
        await fulfillment(of: [began], timeout: 2)
        let adopted = await adapter.adopt(name: "New", runtime: .container(serverId: "host", sandbox: sandbox), spec: nil)
        XCTAssertNotNil(adopted)
        resume?.resume(returning: []); resume = nil
        try await first.value
        XCTAssertEqual(adapter.current().map(\.id), [sandbox.id])

        let second = Task { try await adapter.refresh() }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        XCTAssertNotNil(resume)
        try await adapter.delete(sandbox.id)
        resume?.resume(returning: [try snapshot()]); resume = nil
        try await second.value
        XCTAssertTrue(adapter.current().isEmpty)
    }
}
