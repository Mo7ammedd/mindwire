import Foundation

enum DockerWorkspaceError: LocalizedError {
    case unavailable, missing, ownership, invalid, notPublished
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Docker isn't available for this SSH user. Install or start Docker on the server, then try again."
        case .missing: return "This Docker workspace no longer exists on the server."
        case .ownership: return "This container or volume belongs to another workspace. Mindwire left it unchanged."
        case .invalid: return "The Docker workspace settings are invalid."
        case .notPublished: return "The workspace doesn't have a private connection to the Mindwire service."
        }
    }
}

/// The same placement model as mindwire's ssh({ docker }) SDK target. Docker is
/// used only for the environment lifecycle; agent/control APIs use the native SSH tunnel.
actor DockerWorkspaceHost {
    typealias Execute = @Sendable ([String], Int64) async throws -> ExecResult
    private let engine: DockerEngine
    private let ssh: SSHConnection?

    init(ssh: SSHConnection) {
        self.ssh = ssh
        engine = DockerEngine { arguments, timeout in
            // A login shell includes Docker Desktop/Homebrew paths on macOS hosts.
            try await ssh.exec(["bash", "-lc", SSHConnection.commandString(arguments)], timeoutSeconds: timeout)
        }
    }
    init(execute: @escaping Execute) { engine = DockerEngine(run: execute); ssh = nil }

    private func execute(_ arguments: [String], _ timeout: Int64) async throws -> ExecResult {
        try await engine.exec(arguments, timeout: timeout)
    }

    struct Snapshot: Decodable {
        let id: String
        let owner: String?
        let displayName: String?
        let image: String
        let status: String
        let created: String
        let ports: [Port]?
        let memory: Int64
        let nanoCPUs: Int64
        struct Port: Decodable { let HostIp: String; let HostPort: String }

        var power: WorkspacePower {
            switch status {
            case "running": return .running
            case "restarting": return .starting
            case "created", "exited", "dead", "paused": return .stopped
            default: return .unknown
            }
        }
        var sandbox: ServerSandbox? {
            let prefix = "ghcr.io/oblien/mindwire-runtime:"
            guard let owner, image.hasPrefix(prefix) else { return nil }
            let sandbox = ServerSandbox(id: owner, version: String(image.dropFirst(prefix.count)))
            return sandbox.isValid ? sandbox : nil
        }
    }

    // Deliberately select public metadata; docker inspect's full JSON contains environment secrets.
    private static let format = #"{"id":{{json .Id}},"owner":{{json (index .Config.Labels "io.mindwire.workspace")}},"displayName":{{json (index .Config.Labels "io.mindwire.name")}},"image":{{json .Config.Image}},"status":{{json .State.Status}},"created":{{json .Created}},"ports":{{json (index .NetworkSettings.Ports "8790/tcp")}},"memory":{{.HostConfig.Memory}},"nanoCPUs":{{.HostConfig.NanoCpus}}}"#

    func list() async throws -> [Snapshot] {
        let output = try await checked(["docker", "ps", "-a", "--filter", "label=\(ServerSandbox.ownerLabel)", "--format", "{{.ID}}"])
        let ids = output.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !ids.isEmpty else { return [] }
        let inspected = try await checked(["docker", "inspect", "--format", Self.format] + ids)
        return try inspected.split(separator: "\n").map { try JSONDecoder().decode(Snapshot.self, from: Data($0.utf8)) }
    }

    func inspect(_ sandbox: ServerSandbox) async throws -> Snapshot? {
        guard sandbox.isValid else { throw DockerWorkspaceError.invalid }
        let result = try await execute(["docker", "inspect", "--format", Self.format, sandbox.name], 30)
        if result.exitCode != 0 {
            if result.stderr.localizedCaseInsensitiveContains("no such object")
                || result.stderr.localizedCaseInsensitiveContains("no such container") { return nil }
            throw DockerWorkspaceError.unavailable
        }
        let info = try JSONDecoder().decode(Snapshot.self, from: Data(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        guard info.owner == sandbox.id else { throw DockerWorkspaceError.ownership }
        return info
    }

    func prepare(_ sandbox: ServerSandbox, displayName: String, spec: WorkspaceSpec) async throws {
        guard sandbox.isValid else { throw DockerWorkspaceError.invalid }
        try await engine.ensure()
        if let existing = try await inspect(sandbox) {
            if existing.power != .running { try await power(sandbox, .start) }
            _ = try await port(sandbox)
            return
        }
        let image = try await execute(["docker", "image", "inspect", "--format", "{{.Id}}", sandbox.image], 30)
        if image.exitCode != 0 {
            let pull = try await execute(["docker", "pull", sandbox.image], 900)
            guard pull.exitCode == 0 else {
                throw BackendError.message("Couldn't download the Mindwire sandbox image. \(pull.stderr.oneLine())")
            }
        }
        try await ensureVolume(sandbox)
        let result = try await execute(Self.createArguments(sandbox, displayName: displayName, spec: spec), 60)
        if result.exitCode != 0 {
            // Docker's unique name is the cross-client creation lock. A concurrent request
            // may already have created this exact owned workspace; never make a second one.
            guard let existing = try await inspect(sandbox) else {
                throw BackendError.message("Couldn't create the Docker workspace. \(result.stderr.oneLine())")
            }
            if existing.power != .running { try await power(sandbox, .start) }
        }
        _ = try await port(sandbox)
    }

    private func ensureVolume(_ sandbox: ServerSandbox) async throws {
        let args = ["docker", "volume", "inspect", "--format", "{{index .Labels \"\(ServerSandbox.ownerLabel)\"}}", sandbox.volume]
        var existing = try await execute(args, 30)
        if existing.exitCode != 0 {
            guard existing.stderr.localizedCaseInsensitiveContains("no such volume") else { throw DockerWorkspaceError.unavailable }
            _ = try await checked(["docker", "volume", "create", "--label", "\(ServerSandbox.ownerLabel)=\(sandbox.id)", sandbox.volume])
            existing = try await execute(args, 30)
        }
        guard existing.exitCode == 0, existing.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == sandbox.id else {
            throw DockerWorkspaceError.ownership
        }
    }

    func port(_ sandbox: ServerSandbox) async throws -> Int {
        guard let info = try await inspect(sandbox) else { throw DockerWorkspaceError.missing }
        guard info.power == .running else { throw WorkspaceRegistryError.workspaceNotRunning(info.power) }
        guard let bindings = info.ports, !bindings.isEmpty,
              bindings.allSatisfy({ $0.HostIp == "127.0.0.1" }),
              let port = Int(bindings[0].HostPort), (1...65535).contains(port) else { throw DockerWorkspaceError.notPublished }
        return port
    }

    func exec(_ sandbox: ServerSandbox, _ arguments: [String]) async throws -> ExecResult {
        let info = try await running(sandbox)
        return try await execute(["docker", "exec", "--workdir", ServerSandbox.home, info.id] + arguments, 300)
    }

    nonisolated func execStream(_ sandbox: ServerSandbox, _ arguments: [String]) -> AsyncThrowingStream<ExecEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let ssh = await self.ssh {
                        let info = try await running(sandbox)
                        let command = try await engine.command(["docker", "exec", "--workdir", ServerSandbox.home, info.id] + arguments)
                        for try await event in ssh.execStream(["bash", "-lc", SSHConnection.commandString(command)]) {
                            continuation.yield(event)
                        }
                    } else {
                        let result = try await exec(sandbox, arguments)
                        continuation.yield(.output(Data((result.stdout + "\n" + result.stderr).utf8)))
                        continuation.yield(.exit(result.exitCode))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func terminalCommand(_ sandbox: ServerSandbox, workdir: String?) async throws -> [String] {
        let info = try await running(sandbox)
        return try await engine.command(["docker", "exec", "-it", "--workdir", workdir?.isEmpty == false ? workdir! : ServerSandbox.home,
                                         info.id, "bash", "-l"])
    }

    private func running(_ sandbox: ServerSandbox) async throws -> Snapshot {
        guard let info = try await inspect(sandbox) else { throw DockerWorkspaceError.missing }
        guard info.power == .running else { throw WorkspaceRegistryError.workspaceNotRunning(info.power) }
        return info
    }

    func power(_ sandbox: ServerSandbox, _ action: PowerAction) async throws {
        guard let info = try await inspect(sandbox) else { throw DockerWorkspaceError.missing }
        if action == .start, info.status == "paused" {
            _ = try await checked(["docker", "unpause", info.id])
        } else { _ = try await checked(["docker", action.rawValue, info.id], timeout: 60) }
    }

    func remove(_ sandbox: ServerSandbox) async throws {
        let container = try await inspect(sandbox)
        // Validate both resources before deleting either. A same-named foreign volume
        // must not cause a partially completed deletion.
        let volume = try await execute(["docker", "volume", "inspect", "--format",
            "{{index .Labels \"\(ServerSandbox.ownerLabel)\"}}", sandbox.volume], 30)
        if volume.exitCode == 0 {
            guard volume.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == sandbox.id else { throw DockerWorkspaceError.ownership }
        } else if !volume.stderr.localizedCaseInsensitiveContains("no such volume") {
            throw DockerWorkspaceError.unavailable
        }
        if let container { _ = try await checked(["docker", "rm", "-f", container.id], timeout: 60) }
        if volume.exitCode == 0 { _ = try await checked(["docker", "volume", "rm", sandbox.volume]) }
    }

    private func checked(_ arguments: [String], timeout: Int64 = 30) async throws -> String {
        let result = try await execute(arguments, timeout)
        guard result.exitCode == 0 else { throw DockerWorkspaceError.unavailable }
        return result.stdout
    }

    static func createArguments(_ sandbox: ServerSandbox, displayName: String, spec: WorkspaceSpec) -> [String] {
        ["docker", "run", "--detach", "--init", "--restart", "unless-stopped",
         "--name", sandbox.name, "--label", "\(ServerSandbox.ownerLabel)=\(sandbox.id)",
         "--label", "\(ServerSandbox.nameLabel)=\(displayName)",
         "--publish", "127.0.0.1::8790", "--mount", "type=volume,source=\(sandbox.volume),target=\(ServerSandbox.home)",
         "--user", "node", "--workdir", ServerSandbox.home,
         "--cpus", String(max(1, spec.cpus)), "--memory", "\(max(128, spec.memoryMb))m", "--pids-limit", "1024",
         "--env", "ADDR=0.0.0.0:8790", "--env", "STATE_PATH=\(ServerSandbox.home)/.mindwire/agent-state.json",
         "--env", "MINDWIRE_ISOLATION=container",
         "--env", "AGENT_CWD=\(ServerSandbox.home)", "--entrypoint", "/bin/sh", sandbox.image, "-c", startup]
    }

    /// The volume owns the service binary, auth and project data. A container restart
    /// resumes the installed version; normal idle-guarded updates can replace the daemon
    /// without terminating container PID 1 or recreating the environment.
    static let startup = #"""
    set -eu
    umask 077
    mw_dir="$HOME/.mindwire"
    mkdir -p "$mw_dir"
    if [ ! -s "$mw_dir/daemon.token" ]; then
      node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))' > "$mw_dir/daemon.token"
    fi
    export DAEMON_TOKEN="$(cat "$mw_dir/daemon.token")"
    if [ ! -x "$mw_dir/mindwired" ]; then
      cp /usr/local/bin/mindwired "$mw_dir/mindwired"
      chmod 700 "$mw_dir/mindwired"
    fi
    if [ ! -s "$mw_dir/service.env" ]; then
      /bin/bash -c 'printf "export HOME=%q\nexport PATH=%q\nexport ADDR=%q\nexport AGENT_CWD=%q\n" "$HOME" "$PATH" "$ADDR" "${AGENT_CWD:-}"' > "$mw_dir/service.env"
    fi
    """# + "\n" + """
    cat > "$mw_dir/service-runner.sh.tmp" <<'MINDWIRE_RUNNER'
    \(DaemonStartup.runner)
    MINDWIRE_RUNNER
    chmod 700 "$mw_dir/service-runner.sh.tmp"
    mv -f "$mw_dir/service-runner.sh.tmp" "$mw_dir/service-runner.sh"
    exec /bin/bash "$mw_dir/service-runner.sh" --supervise >> "$mw_dir/mindwire.log" 2>&1
    """
}
