import Foundation

/// A real SSH-backed terminal session over `SSHConnection`. Reads creds (password or a
/// generated key) from the saved server connection, opens a shell+PTY, and bridges bytes
/// to/from SwiftTerm via the `TerminalSession` seam.
final class SSHTerminalSession: TerminalSession {
    var onOutput: ((Data) -> Void)?

    private let connection: SSHConnection
    private let label: String
    private let workdir: String?
    private let sandbox: ServerSandbox?
    private var shell: SSHConnection.ShellHandle?
    private var cols = 80
    private var rows = 24

    init(connection: RemoteHostConnection, workdir: String? = nil, sandbox: ServerSandbox? = nil) {
        label = "\(connection.username)@\(connection.host)"
        self.connection = SSHConnection.make(for: connection)
        self.workdir = workdir
        self.sandbox = sandbox
    }

    func start() {
        emit("Connecting to \(label)…\r\n")
        // start()/resize()/send() all run on the main thread (SwiftUI + SwiftTerm delegate), so
        // snapshot the size here rather than reading cols/rows off-main inside the Task.
        let initialCols = cols
        let initialRows = rows
        Task {
            do {
                let command: [String]?
                if let sandbox {
                    command = try await DockerWorkspaceHost(ssh: connection).terminalCommand(sandbox, workdir: workdir)
                } else { command = nil }
                let handle = try await connection.startShell(cols: initialCols, rows: initialRows, command: command) { [weak self] data in
                    self?.emit(data)
                }
                await MainActor.run {
                    self.shell = handle
                    // Apply any resize that landed while the shell was opening, so the remote PTY
                    // matches the view instead of staying at the initial size.
                    handle.resize(self.cols, self.rows)
                    // cd into the project workdir on open, if one was set.
                    if self.sandbox == nil, let dir = self.workdir, !dir.isEmpty {
                        let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
                        handle.send(Data("cd \(quoted) && clear\n".utf8))
                    }
                }
            } catch {
                emit("\r\n[ssh] \(error.localizedDescription)\r\n")
            }
        }
    }

    func send(_ data: Data) { shell?.send(data) }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        shell?.resize(cols, rows)
    }

    func stop() {
        onOutput = nil
        connection.close()
    }

    private func emit(_ data: Data) {
        DispatchQueue.main.async { [weak self] in self?.onOutput?(data) }
    }
    private func emit(_ text: String) { emit(Data(text.utf8)) }
}
