import Foundation

/// Engine access is separate from workspace placement. Reads only probe; installation
/// or startup is reserved for the explicit "create a sandbox" action.
actor DockerEngine {
    typealias Execute = @Sendable ([String], Int64) async throws -> ExecResult
    private let run: Execute
    private var access: [String]?
    private var checking: Task<[String], Error>?
    private var preparing: Task<Void, Error>?

    init(run: @escaping Execute) { self.run = run }

    func exec(_ arguments: [String], timeout: Int64) async throws -> ExecResult {
        let command = try await command(arguments)
        return try await run(command, timeout)
    }

    func command(_ arguments: [String]) async throws -> [String] {
        try await prefix() + arguments.dropFirst()
    }

    func ensure() async throws {
        do { _ = try await prefix(); return }
        catch DockerWorkspaceError.unavailable {
            if let preparing { return try await preparing.value }
            let task = Task {
                let result = try await run(["bash", "-lc", Self.provisionScript], 900)
                guard result.exitCode == 0 else {
                    let message = (result.stdout + "\n" + result.stderr).components(separatedBy: .newlines)
                        .first { $0.hasPrefix("MINDWIRE_DOCKER_ERROR:") }
                        .map { String($0.dropFirst("MINDWIRE_DOCKER_ERROR:".count)) }
                    throw BackendError.message(message ?? "Docker setup didn't finish. Check Docker on this server, then try again.")
                }
                _ = try await prefix()
            }
            preparing = task
            defer { preparing = nil }
            try await task.value
        }
    }

    private func prefix() async throws -> [String] {
        if let access { return access }
        if let checking { return try await checking.value }
        let run = self.run
        let task = Task {
            let result = try await run(["bash", "-lc", Self.probeScript], 30)
            let fields = Dictionary(result.stdout.components(separatedBy: .newlines).compactMap { line -> (String, String)? in
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, pair[0].hasPrefix("MINDWIRE_DOCKER_") else { return nil }
                return (String(pair[0]), String(pair[1]))
            }, uniquingKeysWith: { _, latest in latest })
            if fields["MINDWIRE_DOCKER_MODE"] == "remote" {
                throw BackendError.message("Select a local Docker engine on this SSH server before creating a workspace.")
            }
            guard result.exitCode == 0, let mode = fields["MINDWIRE_DOCKER_MODE"], ["direct", "sudo"].contains(mode),
                  let path = fields["MINDWIRE_DOCKER_PATH"], path.hasPrefix("/"),
                  let endpoint = fields["MINDWIRE_DOCKER_ENDPOINT"], endpoint.hasPrefix("unix://") else {
                throw DockerWorkspaceError.unavailable
            }
            // Pin this SSH server's socket, independent of later Docker context changes.
            let command = ["env", "-u", "DOCKER_HOST", "-u", "DOCKER_CONTEXT", path, "--host", endpoint]
            return (mode == "sudo" ? ["sudo", "-n"] : []) + command
        }
        checking = task
        defer { checking = nil }
        let command = try await task.value
        access = command
        return command
    }

    static let probeScript = #"""
    # mindwire-docker-probe
    set -eu
    export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin"
    mw_docker=$(command -v docker || true)
    [ -n "$mw_docker" ] || { echo MINDWIRE_DOCKER_MODE=unavailable; exit 0; }
    if [ -n "${DOCKER_HOST:-}" ] && [ -z "${DOCKER_CONTEXT:-}" ]; then
      mw_endpoint=$DOCKER_HOST
    else
      mw_endpoint=$("$mw_docker" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    fi
    case "$mw_endpoint" in
      unix://*) ;;
      '') echo MINDWIRE_DOCKER_MODE=unavailable; exit 0 ;;
      *) echo MINDWIRE_DOCKER_MODE=remote; exit 0 ;;
    esac
    mw_mode=unavailable
    if env -u DOCKER_HOST -u DOCKER_CONTEXT "$mw_docker" --host "$mw_endpoint" info >/dev/null 2>&1; then
      mw_mode=direct
    elif sudo -n env -u DOCKER_HOST -u DOCKER_CONTEXT "$mw_docker" --host "$mw_endpoint" info >/dev/null 2>&1; then
      mw_mode=sudo
    fi
    printf 'MINDWIRE_DOCKER_MODE=%s\nMINDWIRE_DOCKER_PATH=%s\nMINDWIRE_DOCKER_ENDPOINT=%s\n' "$mw_mode" "$mw_docker" "$mw_endpoint"
    """#

    static let provisionScript = #"""
    # mindwire-docker-provision
    set -eu
    export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin"
    fail() { printf 'MINDWIRE_DOCKER_ERROR:%s\n' "$1" >&2; exit 1; }
    case "$(uname -s)" in
      Linux)
        # Rootless installations belong to the SSH user, so try their service first.
        if command -v docker >/dev/null 2>&1; then
          systemctl --user start docker >/dev/null 2>&1 || true
          if docker info >/dev/null 2>&1; then exit 0; fi
        fi
        mw_admin=()
        if [ "$(id -u)" != 0 ]; then
          sudo -n true >/dev/null 2>&1 || fail 'Docker setup needs root or passwordless sudo on this server. Install Docker once, then try again.'
          mw_admin=(sudo -n)
        fi
        if ! command -v docker >/dev/null 2>&1; then
          mw_install=$(mktemp)
          trap 'rm -f "$mw_install"' EXIT
          if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 15 --max-time 90 https://get.docker.com -o "$mw_install"
          elif command -v wget >/dev/null 2>&1; then
            wget -q -T 90 https://get.docker.com -O "$mw_install"
          else
            fail 'Install curl or Docker on this server, then try again.'
          fi
          "${mw_admin[@]}" sh "$mw_install"
        fi
        "${mw_admin[@]}" systemctl start docker >/dev/null 2>&1 || "${mw_admin[@]}" service docker start >/dev/null 2>&1 || true
        ;;
      Darwin)
        [ -d /Applications/Docker.app ] || fail 'Install Docker Desktop on this Mac and open it once, then try again.'
        open -g -a Docker || fail 'Open Docker Desktop on this Mac, then try again.'
        ;;
      *) fail 'Automatic Docker setup supports Linux servers. Install a Docker engine on this host, then try again.' ;;
    esac
    for mw_attempt in {1..90}; do
      if docker info >/dev/null 2>&1 || sudo -n docker info >/dev/null 2>&1; then exit 0; fi
      sleep 1
    done
    fail "Docker didn't start. Open or start Docker on this server, then try again."
    """#
}
