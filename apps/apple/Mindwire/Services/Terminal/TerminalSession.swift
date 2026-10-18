import Foundation

/// A bidirectional PTY stream for a terminal view: raw bytes arrive via `onOutput` (SwiftTerm
/// parses the ANSI/escape sequences natively) and the user's keystrokes go back via `send`.
/// `SSHTerminalSession` connects to a real SSH shell; `NullTerminalSession` is the honest
/// fallback when a target has no shell wired yet.
protocol TerminalSession: AnyObject {
    var onOutput: ((Data) -> Void)? { get set }
    /// Persistent daemon terminals answer terminal device queries while detached.
    /// The view must suppress its own parser-generated replies, including replay.
    var handlesDeviceQueries: Bool { get }
    func start()
    func send(_ data: Data)
    func resize(cols: Int, rows: Int)
    /// Detach this view. Cloud and paired-computer PTYs stay alive server-side;
    /// plain SSH terminals close their shell channel.
    func stop()
    /// Permanently terminate the terminal (closes a cloud PTY via the API). Defaults to `stop()`.
    func kill()
}

extension TerminalSession {
    var handlesDeviceQueries: Bool { false }
    func kill() { stop() }
}

/// Supplies the terminals for a `TerminalScreen`. Cloud workspaces restore existing PTYs (with
/// scrollback). Paired computers restore daemon PTYs; plain SSH hosts make fresh sessions.
protocol TerminalProvider: AnyObject {
    /// Existing terminals to reopen as tabs (empty for hosts without server-side persistence).
    func restoreSessions() async -> [TerminalSession]
    /// A brand-new terminal tab.
    func newSession() -> TerminalSession
    /// Release shared resources (e.g. close the multiplexed socket) when the screen dismisses.
    func teardown()
}

extension TerminalProvider {
    func teardown() {}
}

/// Plain SSH / unsupported targets: nothing to restore; one fresh
/// session per tab via the supplied factory.
final class LocalTerminalProvider: TerminalProvider {
    private let factory: () -> TerminalSession
    init(_ factory: @escaping () -> TerminalSession) { self.factory = factory }
    func restoreSessions() async -> [TerminalSession] { [] }
    func newSession() -> TerminalSession { factory() }
}

/// No-op session for missing/unpaired targets. It prints an "unavailable" line and ignores
/// input; it does NOT simulate a shell.
final class NullTerminalSession: TerminalSession {
    var onOutput: ((Data) -> Void)?

    func start() {
        let text = "\u{1b}[33mTerminal isn't available for this workspace yet.\u{1b}[0m\r\n"
        onOutput?(Data(text.utf8))
    }

    func send(_ data: Data) {}
    func resize(cols: Int, rows: Int) {}
    func stop() { onOutput = nil }
}

/// Chooses the right session for a workspace: a real SSH shell for a self-hosted server, the Oblien
/// runtime WebSocket terminal for cloud, or persistent Mindwire PTYs for paired computers.
enum TerminalSessionFactory {
    /// The terminal provider for a workspace: a cloud workspace multiplexes many PTYs over one socket
    /// (restore + add + close + scrollback); a self-hosted server / unwired target makes fresh
    /// sessions per tab. `workdir` cd's a new shell into a project path.
    static func provider(for workspace: Workspace?, stores: Stores, workdir: String? = nil) -> TerminalProvider {
        switch workspace?.runtime {
        case .local(let computerId):
            #if targetEnvironment(macCatalyst)
            return DaemonTerminalProvider(channel: LocalDaemonChannel(computerId: computerId), workdir: workdir)
            #else
            break
            #endif
        case .cloud(let workspaceId):
            if let workspaceId {
                return CloudTerminalProvider(workspaceId: workspaceId, workdir: workdir)
            }
        case .server(let serverId):
            if let connection = stores.connections.get(serverId) {
                return provider(forConnection: connection, workdir: workdir)
            }
        case .container(let serverId, let sandbox):
            if let remote = stores.connections.get(serverId)?.remote {
                return LocalTerminalProvider { SSHTerminalSession(connection: remote, workdir: workdir, sandbox: sandbox) }
            }
        case nil:
            break
        }
        return LocalTerminalProvider { NullTerminalSession() }
    }

    /// Provider straight to a server connection (the server's "Open terminal").
    static func provider(forConnection connection: Connection, workdir: String? = nil) -> TerminalProvider {
        if case .local(let local) = connection, let computer = local.computer {
            return DaemonTerminalProvider(computer: computer, workdir: workdir)
        }
        return LocalTerminalProvider { make(forConnection: connection, workdir: workdir) }
    }

    /// A session straight to a server connection (used by the server's "Open terminal").
    /// Paired computers always enter through their persistent provider above.
    private static func make(forConnection connection: Connection, workdir: String? = nil) -> TerminalSession {
        if let remote = connection.remote {
            return SSHTerminalSession(connection: remote, workdir: workdir)
        }
        return NullTerminalSession()
    }
}
