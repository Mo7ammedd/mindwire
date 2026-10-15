import XCTest
@testable import Mindwire

final class DockerEngineTests: XCTestCase {
    func testReadsOnlyProbeAndSetupRequiresAnExplicitAction() async throws {
        let fixture = EngineFixture()
        let engine = DockerEngine { args, _ in await fixture.execute(args) }
        do { _ = try await engine.command(["docker", "ps"]); XCTFail("Unavailable engine") }
        catch DockerWorkspaceError.unavailable {}
        let before = await fixture.installs
        XCTAssertEqual(before, 0)
        try await engine.ensure()
        try await engine.ensure()
        let command = try await engine.command(["docker", "ps"])
        XCTAssertEqual(command, ["sudo", "-n", "env", "-u", "DOCKER_HOST", "-u", "DOCKER_CONTEXT",
                                 "/usr/bin/docker", "--host", "unix:///var/run/docker.sock", "ps"])
        let after = await fixture.installs
        XCTAssertEqual(after, 1)
    }

    func testRemoteEngineContextIsRejectedWithoutInstallingAnything() async throws {
        let fixture = EngineFixture(remote: true)
        let engine = DockerEngine { args, _ in await fixture.execute(args) }
        do { try await engine.ensure(); XCTFail("An SSH tunnel cannot forward a different Docker host") }
        catch { XCTAssertTrue(error.localizedDescription.contains("local Docker")) }
        let installs = await fixture.installs
        XCTAssertEqual(installs, 0)
    }
}

private actor EngineFixture {
    let remote: Bool
    private(set) var installs = 0
    init(remote: Bool = false) { self.remote = remote }
    func execute(_ args: [String]) -> ExecResult {
        if args == ["bash", "-lc", DockerEngine.provisionScript] { installs += 1 }
        let mode = remote ? "remote" : (installs == 0 ? "unavailable" : "sudo")
        return .init(exitCode: 0, stdout: "MINDWIRE_DOCKER_MODE=\(mode)\nMINDWIRE_DOCKER_PATH=/usr/bin/docker\nMINDWIRE_DOCKER_ENDPOINT=unix:///var/run/docker.sock\n", stderr: "")
    }
}
