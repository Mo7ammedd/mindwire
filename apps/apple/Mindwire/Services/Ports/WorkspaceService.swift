import Foundation

protocol WorkspaceService: AnyObject {
    var capabilities: WorkspaceCapabilities { get }
    var management: WorkspaceManagementService? { get }
    /// Container networking reaches the container's interface; direct hosts stay on loopback.
    var daemonBindHost: String { get }
    var daemonSupervisor: (any DaemonSupervisor)? { get }
    var usesNativeDaemonService: Bool { get }
    func homeDirectory() async throws -> String
    func status() async throws -> WorkspaceStatus
    func getResources() async throws -> WorkspaceResources
    func updateResources(_ patch: WorkspaceResourcePatch) async throws -> WorkspaceResources
    func power(_ action: PowerAction) async throws
    func listPorts() async throws -> [ExposedPort]
    func exposePort(_ input: ExposePortInput) async throws -> ExposedPort
    func unexposePort(_ port: Int) async throws
    func listFiles(_ path: String) async throws -> [FileEntry]
    /// Backend-executed filename search under `path` (cloud → runtime search; self-hosted → `find`).
    /// Default: unsupported (empty).
    func searchFiles(_ query: String, in path: String) async throws -> [FileEntry]
    func readFile(_ path: String) async throws -> FileContent
    func writeFile(_ path: String, content: String) async throws
    func deleteFile(_ path: String) async throws
    func exec(_ cmd: [String]) async throws -> ExecResult
    /// Run a command and stream its output live, then a final exit event. Default: run it blocking
    /// (`exec`) and emit one output chunk + the exit code. Cloud and SSH stream live.
    func execStream(_ cmd: [String]) -> AsyncThrowingStream<ExecEvent, Error>
    func terminalEndpoint() async throws -> WorkspaceTerminalEndpoint
    /// Current usage from the **management** stats endpoint (`GET /workspace/:id/stats`) — an
    /// instant first value. Default: unsupported (nil), e.g. self-hosted.
    func stats() async throws -> WorkspaceStatsSample?
    /// Live usage from the **management** SSE stream (`/workspace/:id/stats/stream`). Default:
    /// unsupported (empty stream).
    func statsStream() -> AsyncThrowingStream<WorkspaceStatsSample, Error>
}

extension WorkspaceService {
    var management: WorkspaceManagementService? { nil }
    var daemonBindHost: String { "127.0.0.1" }
    var daemonSupervisor: (any DaemonSupervisor)? { nil }
    var usesNativeDaemonService: Bool { true }
    /// The platform shell used to build exec commands. Linux/POSIX today; a future non-Linux
    /// workspace would promote this to a protocol requirement and return its own `Shell`.
    var shell: Shell { PosixShell() }
    func homeDirectory() async throws -> String {
        try await exec(shell.command(shell.home())).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func searchFiles(_ query: String, in path: String) async throws -> [FileEntry] { [] }
    func stats() async throws -> WorkspaceStatsSample? { nil }
    func statsStream() -> AsyncThrowingStream<WorkspaceStatsSample, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func execStream(_ cmd: [String]) -> AsyncThrowingStream<ExecEvent, Error> {
        bufferedExecStream(cmd)
    }
    /// Fallback for backends that only expose completed commands.
    func bufferedExecStream(_ cmd: [String]) -> AsyncThrowingStream<ExecEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let r = try await exec(cmd)
                    let combined = [r.stdout, r.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                    if !combined.isEmpty { continuation.yield(.output(Data(combined.utf8))) }
                    continuation.yield(.exit(r.exitCode))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A chunk of live command output, or the final exit code.
enum ExecEvent: Sendable {
    case output(Data)
    case exit(Int?)
}
