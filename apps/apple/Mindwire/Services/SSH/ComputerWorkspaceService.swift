import Foundation

/// Maps the existing workspace port onto native daemon APIs. The filesystem, Git,
/// projects, agents and terminal screens don't branch on a computer connection.
final class ComputerWorkspaceService: DaemonWorkspaceService {
    let capabilities = WorkspaceCapabilities.selfHosted
    let channel: ComputerDaemonChannel
    let computer: PairedComputer
    var daemonToken: String? { Keychain.get(computer.tokenRef) }
    var daemonChannel: any StreamingDaemonChannel { channel }
    init(computer: PairedComputer, network: ComputerNetworkMonitor = .shared) {
        self.computer = computer; channel = ComputerDaemonChannel(computer: computer, network: network)
    }
}

/// Local and paired computers share the same workspace HTTP API.
protocol DaemonWorkspaceService: WorkspaceService {
    var daemonChannel: any StreamingDaemonChannel { get }
    var daemonToken: String? { get }
}

extension DaemonWorkspaceService {
    private var http: DaemonHTTP { DaemonHTTP(channel: daemonChannel, agentType: "") }
    func homeDirectory() async throws -> String {
        let host: ComputerHost = try await http.decode("GET", "/workspace/host", quiet: true)
        return host.home
    }
    func status() async throws -> WorkspaceStatus {
        let _: ComputerHost = try await http.decode("GET", "/workspace/host", quiet: true)
        return WorkspaceStatus(power: .running)
    }
    func getResources() async throws -> WorkspaceResources { try await http.decode("GET", "/workspace/resources") }
    func listFiles(_ path: String) async throws -> [FileEntry] { try await http.decode("GET", "/workspace/files?path=\(http.encQuery(path))") }
    func searchFiles(_ query: String, in path: String) async throws -> [FileEntry] {
        try await http.decode("GET", "/workspace/files?path=\(http.encQuery(path))&query=\(http.encQuery(query))")
    }
    func readFile(_ path: String) async throws -> FileContent { try await http.decode("GET", "/workspace/file?path=\(http.encQuery(path))") }
    func writeFile(_ path: String, content: String) async throws { _ = try await http.run("PUT", "/workspace/file", json: ["path": path, "content": content]) }
    func deleteFile(_ path: String) async throws { _ = try await http.run("DELETE", "/workspace/file?path=\(http.encQuery(path))", json: nil) }
    func exec(_ cmd: [String]) async throws -> ExecResult { try await http.decode("POST", "/workspace/exec", json: ["argv": cmd]) }
    func execStream(_ cmd: [String]) -> AsyncThrowingStream<ExecEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONSerialization.data(withJSONObject: ["argv": cmd])
                    let stream = try await self.daemonChannel.stream(method: "POST", path: "/workspace/exec/stream", jsonBody: body)
                    for try await bytes in stream {
                        let frame = try JSONDecoder().decode(DaemonExecFrame.self, from: bytes)
                        switch frame.kind {
                        case "output": if let data = frame.data { continuation.yield(.output(data)) }
                        case "exit": continuation.yield(.exit(frame.exitCode))
                        case "error": throw BackendError.message(frame.error ?? "The command failed.")
                        default: throw BackendError.message("Unknown command stream response.")
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func updateResources(_ patch: WorkspaceResourcePatch) async throws -> WorkspaceResources { throw unsupported() }
    func power(_ action: PowerAction) async throws { throw unsupported() }
    func listPorts() async throws -> [ExposedPort] { [] }
    func exposePort(_ input: ExposePortInput) async throws -> ExposedPort { throw unsupported() }
    func unexposePort(_ port: Int) async throws { throw unsupported() }
    func terminalEndpoint() async throws -> WorkspaceTerminalEndpoint { throw unsupported() }
    private func unsupported() -> BackendError { .message("This operation isn't available for a personal computer.") }
}

private struct DaemonExecFrame: Decodable {
    let kind: String
    var data: Data?
    var exitCode: Int?
    var error: String?
}
