import Foundation
import OblienKit

/// Per-workspace owner of the **one** multiplexed terminal socket (`TerminalMux`) and the terminal
/// lifecycle API. Every tab/session for a workspace shares a single hub, so every PTY rides the
/// same socket instead of each opening its own (which the runtime treats as a takeover). The hub
/// single-flights the socket so concurrent tabs don't race two connections open.
actor CloudTerminalHub {
    let workspaceId: String
    private var runtime: RuntimeClient?
    private var mux: TerminalMux?
    private var muxTask: Task<TerminalMux, Error>?

    init(workspaceId: String) { self.workspaceId = workspaceId }

    private func ensureRuntime() async throws -> RuntimeClient {
        if let runtime { return runtime }
        let rt = try await MindwireCloud.workspace(workspaceId).runtime()
        runtime = rt
        return rt
    }

    /// The shared, connected multiplexed socket — created once and reused by every terminal.
    func ensureMux() async throws -> TerminalMux {
        if let mux { return mux }
        if let muxTask { return try await muxTask.value }
        let task = Task { () throws -> TerminalMux in try await ensureRuntime().terminalMux() }
        muxTask = task
        do {
            let m = try await task.value
            mux = m
            return m
        } catch {
            muxTask = nil
            throw error
        }
    }

    /// Add a PTY (`POST /terminals`) → its multiplexing id.
    func createTerminal(cols: Int, rows: Int) async throws -> Int {
        try await ensureRuntime().terminal.create(cols: cols, rows: rows).id
    }

    /// Ids of the live PTYs to reopen as tabs (`GET /terminals`).
    func liveTerminals() async -> [Int] {
        guard let rt = try? await ensureRuntime() else { return [] }
        let list = (try? await rt.terminal.list()) ?? []
        return list.filter { $0.alive ?? true }.map { $0.id }
    }

    /// Replayable buffer for a terminal (`GET /terminals/:id/scrollback`) — the "rollback".
    func scrollback(_ id: Int) async -> Data {
        guard let rt = try? await ensureRuntime() else { return Data() }
        return (try? await rt.terminal.scrollback(id)) ?? Data()
    }

    /// Permanently kill a PTY (`DELETE /terminals/:id`).
    func closeTerminal(_ id: Int) async {
        guard let rt = try? await ensureRuntime() else { return }
        try? await rt.terminal.close(id)
    }

    /// Drop the shared socket (the PTYs stay alive server-side for the next open).
    func disconnect() {
        mux?.close()
        mux = nil
        muxTask = nil
    }
}

/// `TerminalProvider` for Oblien Cloud: every tab shares one `CloudTerminalHub`. Existing PTYs are
/// restored as tabs (with scrollback replayed); a new tab adds a PTY. The whole socket is dropped
/// on teardown, leaving the PTYs alive for the next open.
final class CloudTerminalProvider: TerminalProvider {
    private let hub: CloudTerminalHub
    private let workdir: String?

    init(workspaceId: String, workdir: String?) {
        self.hub = CloudTerminalHub(workspaceId: workspaceId)
        self.workdir = workdir
    }

    func restoreSessions() async -> [TerminalSession] {
        // A project terminal (has a workdir) should open a fresh shell in that folder, not reattach
        // to terminals living elsewhere — so only the bare workspace terminal restores existing PTYs.
        guard workdir == nil else { return [] }
        let ids = await hub.liveTerminals()
        return ids.map { CloudTerminalSession(hub: hub, terminalId: $0, restoreBuffer: true) }
    }

    func newSession() -> TerminalSession {
        CloudTerminalSession(hub: hub, terminalId: nil, restoreBuffer: false, workdir: workdir)
    }

    func teardown() {
        Task { await hub.disconnect() }
    }
}
