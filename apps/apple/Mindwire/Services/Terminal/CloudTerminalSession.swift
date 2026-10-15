import Foundation
import OblienKit

/// One terminal tab for an Oblien Cloud workspace. It does **not** own a socket — it borrows the
/// workspace's shared `TerminalMux` from `CloudTerminalHub` and routes by its PTY id, so many tabs
/// coexist on one connection. A restored tab reattaches to an existing PTY and replays its
/// scrollback ("rollback"); a fresh tab creates a PTY (`POST /terminals`) and cd's into `workdir`.
final class CloudTerminalSession: TerminalSession {
    var onOutput: ((Data) -> Void)?

    private let hub: CloudTerminalHub
    private let restoreBuffer: Bool
    private let workdir: String?

    private var mux: TerminalMux?
    private var terminalId: Int?
    private var cols = 80
    private var rows = 24
    private var started = false

    init(hub: CloudTerminalHub, terminalId: Int? = nil, restoreBuffer: Bool = false, workdir: String? = nil) {
        self.hub = hub
        self.terminalId = terminalId
        self.restoreBuffer = restoreBuffer
        self.workdir = workdir
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            do {
                let mux = try await hub.ensureMux()
                let isNew = (terminalId == nil)
                let id: Int
                if let existing = terminalId {
                    id = existing
                } else {
                    id = try await hub.createTerminal(cols: cols, rows: rows)
                }
                self.terminalId = id
                self.mux = mux

                // Wire output before doing anything else so replayed bytes aren't missed.
                mux.attach(id) { [weak self] data in
                    DispatchQueue.main.async { self?.onOutput?(data) }
                }

                // Reattaching to an existing PTY → replay its buffer so the tab isn't blank.
                if restoreBuffer {
                    let buffer = await hub.scrollback(id)
                    if !buffer.isEmpty {
                        DispatchQueue.main.async { [weak self] in self?.onOutput?(buffer) }
                    }
                }

                // Only a brand-new shell needs to be dropped into the project folder.
                if isNew, let workdir, !workdir.isEmpty {
                    mux.send(id, Data("cd \(Self.shellQuoted(workdir)) 2>/dev/null\r".utf8))
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.onOutput?(Data("\r\n\u{1b}[31mTerminal failed: \(error.localizedDescription)\u{1b}[0m\r\n".utf8))
                }
            }
        }
    }

    func send(_ data: Data) {
        guard let id = terminalId else { return }
        mux?.send(id, data)
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        guard let id = terminalId else { return }
        mux?.resize(id, cols: cols, rows: rows)
    }

    /// Detach the view but leave the PTY running server-side (restored on the next open).
    func stop() {
        if let id = terminalId { mux?.detach(id) }
        onOutput = nil
    }

    /// Closing the tab permanently kills the PTY (`DELETE /terminals/:id`).
    func kill() {
        if let id = terminalId {
            mux?.detach(id)
            Task { [hub] in await hub.closeTerminal(id) }
        }
        onOutput = nil
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
