import XCTest
@testable import Mindwire

/// Opt-in check against a disposable SSH/Docker host. The fixture owns only an
/// ephemeral SSH key; this never uses a production server or model API credential.
@MainActor
final class DockerWorkspaceLiveTests: XCTestCase {
    func testContainerThroughNativeSSH() async throws {
        guard let path = ProcessInfo.processInfo.environment["MINDWIRE_DOCKER_LIVE_FIXTURE"] else {
            throw XCTSkip("Set MINDWIRE_DOCKER_LIVE_FIXTURE for a disposable SSH/Docker host.")
        }
        struct Fixture: Decodable {
            let host: String
            let port: Int
            let username: String
            let privateKey: String
            let imageVersion: String
            let serviceVersion: String
            let serviceArtifact: String?
        }
        let config = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sandbox = ServerSandbox(id: id, version: config.imageVersion)
        let secret = "mindwire-docker-fixture-" + id
        Keychain.set(config.privateKey, for: secret)
        let remote = RemoteHostConnection(id: "docker-fixture-" + id, name: "Disposable Docker check", type: .ssh,
            host: config.host, port: config.port, username: config.username, auth: .key(secretRef: secret), createdAt: isoNow())
        let connection = Connection.ssh(remote)
        let ssh = SSHConnection.make(for: remote)
        let host = DockerWorkspaceHost(ssh: ssh)
        addTeardownBlock {
            defer { ssh.close(); Keychain.delete(secret); Keychain.delete(KeychainKey.runtimeToken(id)) }
            try await host.remove(sandbox)
        }
        let provisioner = SelfHostedProvisioner(connection: connection, name: "Native SSH live check", sandbox: sandbox,
                                               serviceVersion: config.serviceVersion, makeInstaller: { workspace in
            if let artifact = config.serviceArtifact {
                return FixtureDaemonInstaller(workspace: workspace, ssh: ssh, host: host, sandbox: sandbox, artifact: artifact)
            }
            return ExecDaemonInstaller(workspace: workspace)
        })
        let spec = WorkspaceSpec(cpus: 1, memoryMb: 1024, diskMb: 0, persistent: true)
        let runtime = try await provisioner.provision(spec, onStage: nil)
        XCTAssertEqual(runtime, .container(serverId: remote.id, sandbox: sandbox))
        let workspace = DockerWorkspaceService(host: host, sandbox: sandbox)
        let token = await WorkspaceDaemonCredential.resolve(workspaceId: id, workspace: workspace)
        let channel = SSHTunnelChannel(ssh: ssh, token: token) { try await host.port(sandbox) }
        let http = DaemonHTTP(channel: channel, agentType: "")
        let health: DaemonHealth = try await http.decode("GET", "/healthz", quiet: true)
        XCTAssertTrue(health.ok)
        XCTAssertTrue(DaemonRelease.satisfies(health.version, target: config.serviceVersion))
        XCTAssertEqual(health.workspaceIsolationVersion, 1)
        XCTAssertEqual(health.workspaceIsolation, "container")
        let inspected = try await host.inspect(sandbox)
        let initial = try XCTUnwrap(inspected)
        XCTAssertEqual(initial.ports?.first?.HostIp, "127.0.0.1")

        // File APIs and durable project operations address the container. Their
        // resulting metadata and SSE are read using the exact native daemon channel.
        let directory = ServerSandbox.home + "/native-check"
        let made = try await workspace.exec(["mkdir", "-p", directory])
        XCTAssertEqual(made.exitCode, 0)
        try await workspace.writeFile(directory + "/persist.txt", content: "Keep across restart ✓")
        let operation: ProjectOperation = try await http.decode("POST", "/workspace/projects", json: [
            "id": "native-check-" + id, "source": "folder", "name": "Native check", "path": directory
        ])
        let feed = try await channel.stream(method: "GET", path: "/workspace/operations/\(operation.id)/stream", jsonBody: nil)
        var finished: ProjectOperation?
        for try await event in feed {
            let update = try JSONDecoder().decode(ProjectOperation.self, from: event)
            if !update.isActive { finished = update; break }
        }
        XCTAssertEqual(finished?.status, "succeeded")
        let before: WorkspaceMetadata = try await http.decode("GET", "/workspace", quiet: true)
        XCTAssertTrue(before.projects.contains { $0.path == directory })

        // The real Codex CLI talks only to this deterministic local Responses fixture.
        // Exercise the app's actual agent transport, native tools, live parsing and resume.
        let fixturePath = ServerSandbox.home + "/model-fixture.cjs"
        try await workspace.writeFile(fixturePath, content: Self.modelFixture)
        let started = try await workspace.exec(["bash", "-lc",
            "nohup " + SSHConnection.commandString(["node", fixturePath]) + " > /home/node/model-fixture.log 2>&1 < /dev/null &"])
        XCTAssertEqual(started.exitCode, 0)
        let ready = try await workspace.exec(["bash", "-lc",
            "for i in {1..40}; do curl -fsS http://127.0.0.1:8989/health >/dev/null 2>&1 && exit 0; sleep .1; done; exit 1"])
        XCTAssertEqual(ready.exitCode, 0)
        let transport = ExecDaemonTransport(channel: channel, agentType: "codex")
        let auth = try await transport.authStep(["apiKey": "mindwire-local-test", "baseUrl": "http://127.0.0.1:8989"])
        XCTAssertEqual(auth.status, "complete")
        try await transport.setConfig(["model": "gpt-5.5"])
        let chatID = "native-chat-" + id
        var threadID: String?
        for turn in 1...2 {
            let run = try await transport.sendTurn(chatId: chatID, message: "Native check \(turn)", cwd: directory)
            let stream = try XCTUnwrap(transport.streamRun(run.id))
            var events: [DaemonEvent] = []
            for try await event in stream { events.append(event) }
            let result = try XCTUnwrap(events.last { $0.type == .result }?.result)
            XCTAssertNotEqual(result.isError, true, result.text ?? "Codex failed")
            XCTAssertEqual(result.text, "Native reply \(turn)")
            if turn == 1 {
                threadID = result.sessionId
                XCTAssertTrue(events.contains { $0.type == .tool_use })
                XCTAssertTrue(events.contains { $0.type == .tool_result })
                XCTAssertFalse(events.contains { $0.type == .tool_result && $0.tool?.isError == true })
            } else { XCTAssertEqual(result.sessionId, threadID) }
        }
        XCTAssertNotNil(threadID)
        let shellFile = try await workspace.readFile(directory + "/shell-live.txt")
        XCTAssertEqual(shellFile.content, "shell through container\n")
        let patchFile = try await workspace.readFile(directory + "/codex-live.txt")
        XCTAssertEqual(patchFile.content, "created by native apply_patch\n")
        let chatBefore = try await transport.listMessages(chatId: chatID, limit: nil, before: nil)
        XCTAssertEqual(chatBefore.filter { $0.role == .assistant }.map(\.text), ["Native reply 1", "Native reply 2"])
        XCTAssertTrue(chatBefore.contains { $0.parts?.contains { $0.kind == .tool } == true })

        let output = expectation(description: "The native SSH PTY runs inside the container")
        var terminalText = ""
        var fulfilled = false
        let command = try await host.terminalCommand(sandbox, workdir: directory)
        let handle = try await ssh.startShell(cols: 80, rows: 24, command: command) { data in
            Task { @MainActor in
                terminalText += String(decoding: data, as: UTF8.self)
                if !fulfilled, terminalText.contains("MINDWIRE_INSIDE_OK") { fulfilled = true; output.fulfill() }
            }
        }
        handle.send(Data("test -f /.dockerenv && test -f persist.txt && printf '\\nMINDWIRE_%s\\n' INSIDE_OK\n".utf8))
        await fulfillment(of: [output], timeout: 10)

        _ = try await provisioner.provision(spec, onStage: nil)
        let reused = try await host.inspect(sandbox)
        XCTAssertEqual(reused?.id, initial.id, "Retry must adopt the same environment")
        try await workspace.power(.stop)
        let stopped = try await workspace.status()
        XCTAssertEqual(stopped.power, .stopped)
        do { _ = try await host.port(sandbox); XCTFail("Reads cannot wake a stopped container") }
        catch WorkspaceRegistryError.workspaceNotRunning(.stopped) {}
        try await workspace.power(.start)
        // Daemon listeners can take a moment after Docker reports the container running.
        var restarted: DaemonHealth?
        for _ in 0..<40 {
            if let value: DaemonHealth = try? await http.decode("GET", "/healthz", quiet: true), value.ok {
                restarted = value; break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(DaemonRelease.satisfies(restarted?.version, target: config.serviceVersion),
                      "Restart must keep the updated volume binary, not revert to the image version")
        let file = try await workspace.readFile(directory + "/persist.txt")
        XCTAssertEqual(file.content, "Keep across restart ✓")
        let after: WorkspaceMetadata = try await http.decode("GET", "/workspace", quiet: true)
        XCTAssertEqual(after.workspaceId, before.workspaceId)
        XCTAssertEqual(after.projects.map(\.id), before.projects.map(\.id))
        let chatAfter = try await transport.listMessages(chatId: chatID, limit: nil, before: nil)
        XCTAssertEqual(chatAfter.map(\.id), chatBefore.map(\.id))
        XCTAssertEqual(chatAfter.map(\.text), chatBefore.map(\.text))
        let authAfter = try await transport.authStatus()
        XCTAssertTrue(authAfter.configured)
        let credential = await WorkspaceDaemonCredential.resolve(workspaceId: id, workspace: workspace)
        XCTAssertEqual(credential, token)
        let inventory = try await host.list()
        XCTAssertEqual(inventory.filter { $0.owner == id }.count, 1)
        print("DOCKER_CHECK native SSH HTTP/SSE, Codex tools/resume/history, container PTY, service update, retry, restart, data and credentials passed")
    }

    private static let modelFixture = #"""
    const http = require('node:http');
    let requests = 0;
    function tools(list) {
      return (list || []).flatMap(t => t.tools ? tools(t.tools) : [t.function || t]);
    }
    http.createServer(async (req, res) => {
      if (req.url === '/health') { res.end('ok'); return; }
      if (req.method !== 'POST' || !req.url.endsWith('/responses')) { res.writeHead(404); res.end(); return; }
      if (req.headers.authorization !== 'Bearer mindwire-local-test') { res.writeHead(401); res.end(); return; }
      let body = '';
      for await (const chunk of req) body += chunk;
      const request = JSON.parse(body), available = tools(request.tools), n = ++requests;
      const id = 'item_local_' + n;
      let item;
      if (n <= 2) {
        const names = n === 1 ? ['exec_command', 'shell_command', 'shell'] : ['apply_patch'];
        const tool = available.find(t => names.includes(t.name));
        if (!tool) { res.writeHead(500); res.end('Missing native tool: ' + available.map(t => t.name).join(',')); return; }
        const command = "printf 'shell through container\\n' > shell-live.txt";
        const patch = '*** Begin Patch\n*** Add File: codex-live.txt\n+created by native apply_patch\n*** End Patch';
        if (tool.type === 'custom') {
          item = { id, type: 'custom_tool_call', call_id: 'call_' + n, name: tool.name, input: patch };
        } else {
          const args = n === 2 ? { patch } : tool.name === 'exec_command' ? { cmd: command, max_output_tokens: 200, yield_time_ms: 1000 }
            : { command: tool.name === 'shell' ? ['/bin/sh', '-lc', command] : command };
          item = { id, type: 'function_call', call_id: 'call_' + n, name: tool.name, arguments: JSON.stringify(args) };
        }
      } else {
        item = { id, type: 'message', role: 'assistant', status: 'completed', phase: 'final_answer',
          content: [{ type: 'output_text', text: 'Native reply ' + (n - 2), annotations: [] }] };
      }
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      function emit(event) { res.write('event: ' + event.type + '\ndata: ' + JSON.stringify(event) + '\n\n'); }
      emit({ type: 'response.output_item.added', output_index: 0, item });
      if (item.type === 'message') {
        emit({ type: 'response.output_text.delta', item_id: id, output_index: 0, content_index: 0, delta: item.content[0].text });
      }
      emit({ type: 'response.output_item.done', output_index: 0, item });
      emit({ type: 'response.completed', response: { id: 'resp_local_' + n, object: 'response', status: 'completed',
        output: [item], usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 } } });
      res.end();
    }).listen(8989, '127.0.0.1');
    """#
}

/// Optional development artifact, used only on the disposable test host before
/// a release exists. Production provisioning always downloads a GitHub release.
private struct FixtureDaemonInstaller: DaemonInstaller {
    let workspace: WorkspaceService
    let ssh: SSHConnection
    let host: DockerWorkspaceHost
    let sandbox: ServerSandbox
    let artifact: String

    func install(agentType: String, cwd: String, target: String, daemonToken: String,
                 requireUpdateLease: Bool, force: Bool, onProgress: (@Sendable (DaemonInstallProgress) -> Void)?) async throws {
        let snapshot = try await host.inspect(sandbox)
        let id = try XCTUnwrap(snapshot?.id)
        let path = ServerSandbox.home + "/.mindwire/fixture.b64"
        let engine = DockerEngine { args, timeout in
            try await ssh.exec(["bash", "-lc", SSHConnection.commandString(args)], timeoutSeconds: timeout)
        }
        let copied = try await engine.exec(["docker", "cp", artifact, id + ":" + path], timeout: 60)
        XCTAssertEqual(copied.exitCode, 0)
        let destination = DaemonBootstrap.Destination(platform: .linux, arch: "arm64", directory: ServerSandbox.home + "/.mindwire")
        let script = DaemonBootstrap.installScript(destination: destination, source: .upload(path: path),
            agentType: agentType, cwd: cwd, target: target, daemonToken: daemonToken,
            requireUpdateLease: requireUpdateLease, force: force, bindHost: workspace.daemonBindHost)
        let result = try await workspace.exec(["bash", "-lc", script])
        guard result.stdout.contains("DAEMON_OK") else {
            throw BackendError.message("Fixture service update failed: " + String((result.stdout + "\n" + result.stderr).suffix(4000)))
        }
    }
}
