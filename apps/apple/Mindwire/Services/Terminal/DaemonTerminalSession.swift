import Foundation
import UIKit

struct DaemonTerminalState: Codable {
    let id: String
    let directory: String
    let title: String
    let columns: Int
    let rows: Int
    let running: Bool
    let exitCode: Int?
    let createdAt: String
}
struct DaemonTerminalEvent: Decodable {
    let sequence: UInt64
    let kind: String
    var data: Data?
    var state: DaemonTerminalState?
}

final class DaemonTerminalProvider: TerminalProvider {
    private let channel: any StreamingDaemonChannel
    private let workdir: String?
    private var closing: [Task<Void, Never>] = []
    private let closeChannel: () async -> Void
    init(computer: PairedComputer, workdir: String?, network: ComputerNetworkMonitor = .shared) {
        let channel = ComputerDaemonChannel(computer: computer, network: network)
        self.channel = channel; self.workdir = workdir
        closeChannel = { await channel.close() }
    }
    init(channel: any StreamingDaemonChannel, workdir: String?) {
        self.channel = channel; self.workdir = workdir; closeChannel = {}
    }
    func restoreSessions() async -> [TerminalSession] {
        let http = DaemonHTTP(channel: channel, agentType: "")
        do {
            let query = workdir.map { "?directory=\(http.encQuery($0))" } ?? ""
            let states: [DaemonTerminalState] = try await http.decode("GET", "/workspace/terminals\(query)", quiet: true)
            return states.map { makeSession(state: $0, directory: $0.directory) }
        } catch {
            // A failed list must not create a duplicate shell. This session retries
            // listing on Start and reports the connection issue in the existing view.
            return [makeSession(recoverExisting: true)]
        }
    }
    func newSession() -> TerminalSession { makeSession() }
    private func makeSession(state: DaemonTerminalState? = nil, directory: String? = nil, recoverExisting: Bool = false) -> DaemonTerminalSession {
        DaemonTerminalSession(channel: channel, state: state, workdir: directory ?? workdir, recoverExisting: recoverExisting) { [weak self] id in
            guard let self else { return }
            let http = DaemonHTTP(channel: self.channel, agentType: "")
            let task = Task {
                for attempt in 0..<3 {
                    do { _ = try await http.run("DELETE", "/workspace/terminals/\(id)", json: nil, quiet: true); return }
                    catch { if attempt < 2 { try? await Task.sleep(for: .seconds(1)) } }
                }
            }
            self.closing.append(task)
        }
    }
    func teardown() {
        let closing = self.closing, closeChannel = self.closeChannel
        Task { for task in closing { await task.value }; await closeChannel() }
    }
}

/// One daemon-owned PTY. All mutable state is on the main queue; HTTP/SSE suspend
/// off it. Keystrokes are serialized and retried with the same receipt ID.
final class DaemonTerminalSession: TerminalSession {
    var onOutput: ((Data) -> Void)?
    var onConnectionChange: ((TerminalConnectionState) -> Void)?
    private(set) var connectionState: TerminalConnectionState = .connecting {
        didSet { if oldValue != connectionState { onConnectionChange?(connectionState) } }
    }
    let handlesDeviceQueries = true
    private let channel: any StreamingDaemonChannel
    private var http: DaemonHTTP { DaemonHTTP(channel: channel, agentType: "") }
    private let workdir: String?
    private var terminalId: String
    private let writer = UUID().uuidString
    private var inputSequence: UInt64 = 0
    private var cursor: UInt64 = 0
    private var columns = 80, rows = 24
    private var appliedColumns: Int?
    private var appliedRows: Int?
    private var opened: Bool
    private var recoverExisting: Bool
    private var running = true
    private var attached = false
    private var generation = 0
    private var inputs = TerminalInputBuffer()
    private var inputFailure: String?
    private var feedFailure: String?
    private var feedTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private let closeTerminal: (String) -> Void

    init(channel: any StreamingDaemonChannel, state: DaemonTerminalState? = nil, workdir: String?, recoverExisting: Bool = false,
         closeTerminal: @escaping (String) -> Void) {
        self.channel = channel; self.workdir = workdir
        terminalId = state?.id ?? UUID().uuidString
        opened = state != nil; running = state?.running ?? true; self.recoverExisting = recoverExisting
        appliedColumns = state?.columns; appliedRows = state?.rows
        self.closeTerminal = closeTerminal
    }

    func start() {
        guard !attached else { return }; attached = true
        connectionState = .connecting
        generation += 1
        let generation = self.generation
        feedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var reconnectAttempts = 0
            var connectedAt = Date()
            while !Task.isCancelled, self.attached, generation == self.generation {
                do {
                    if self.recoverExisting {
                        let query = self.workdir.map { "?directory=\(self.http.encQuery($0))" } ?? ""
                        let states: [DaemonTerminalState] = try await self.http.decode("GET", "/workspace/terminals\(query)", quiet: true)
                        try Task.checkCancellation()
                        guard generation == self.generation else { return }
                        if let state = states.first(where: \.running) ?? states.first {
                            self.terminalId = state.id; self.opened = true; self.apply(state)
                        }
                        self.recoverExisting = false
                    }
                    if !self.opened {
                        let state: DaemonTerminalState = try await self.http.decode("POST", "/workspace/terminals", json: [
                            "id": self.terminalId, "directory": self.workdir ?? "", "columns": self.columns, "rows": self.rows
                        ], quiet: true)
                        try Task.checkCancellation()
                        guard generation == self.generation else { return }
                        self.opened = true; self.apply(state)
                    } else {
                        // A quiet PTY may emit no bytes after reconnecting. Confirm
                        // the same shell with a read; never recreate it or wait for
                        // output to decide whether the connection recovered.
                        let state: DaemonTerminalState = try await self.http.decode("GET", self.path, quiet: true)
                        try Task.checkCancellation()
                        guard generation == self.generation else { return }
                        self.apply(state)
                    }
                    guard self.running else { self.connectionState = .ended; return }
                    self.didConnect()
                    self.flushInput()
                    if self.running { self.scheduleResize() }
                    connectedAt = Date()
                    let events = try await self.channel.stream(method: "GET", path: self.path + "/events?after=\(self.cursor)", jsonBody: nil)
                    for try await data in events {
                        try Task.checkCancellation()
                        guard generation == self.generation else { return }
                        let event = try JSONDecoder().decode(DaemonTerminalEvent.self, from: data)
                        guard event.kind == "reset" || event.sequence > self.cursor else { continue }
                        guard ["output", "reset", "exit"].contains(event.kind) else { continue }
                        if let bytes = event.data { self.onOutput?(bytes) }
                        self.cursor = event.sequence
                        if let state = event.state { self.apply(state) }
                        if event.kind == "exit" { self.running = false; self.connectionState = .ended; return }
                        reconnectAttempts = 0
                        self.didConnect()
                    }
                    if !self.running { return }
                    throw ComputerConnectionError.unreachable
                } catch {
                    if Task.isCancelled || !self.attached || generation != self.generation { return }
                    if error is DecodingError {
                        APILog.note("terminal received an invalid update [\(self.channel.label)]")
                        let detail = "This computer sent an invalid terminal update. Update Mindwire on the computer and retry."
                        self.feedFailure = detail
                        self.connectionState = .failed(detail)
                        return
                    }
                    if let api = error as? DaemonHTTPError, [400, 401, 403, 404, 409].contains(api.status) {
                        self.feedFailure = api.localizedDescription
                        self.connectionState = .failed(api.localizedDescription); return
                    }
                    self.connectionState = self.inputFailure.map(TerminalConnectionState.failed) ?? .reconnecting
                    APILog.note("terminal stream disconnected [\(self.channel.label)]: \(error.localizedDescription.oneLine())")
                    if Date().timeIntervalSince(connectedAt) > 10 { reconnectAttempts = 0 }
                    let delay = 250 * (1 << min(reconnectAttempts, 4))
                    reconnectAttempts = min(4, reconnectAttempts + 1)
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                }
            }
        }
    }

    func send(_ data: Data) {
        guard running, !data.isEmpty else { return }
        guard inputs.append(data) else {
            connectionState = .failed("The input queue is full. Waiting input has been kept; wait for the computer before typing more.")
            return
        }
        flushInput()
    }
    private func flushInput() {
        guard opened, attached, running, inputFailure == nil, feedFailure == nil, inputTask == nil, !inputs.isEmpty else { return }
        let generation = self.generation
        inputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var reconnectAttempts = 0
            defer { if generation == self.generation { self.inputTask = nil } }
            while !Task.isCancelled, self.attached, self.running, self.inputFailure == nil, self.feedFailure == nil,
                  generation == self.generation, let bytes = self.inputs.next() {
                let sequence = self.inputSequence + 1
                do {
                    _ = try await self.http.run("POST", self.path + "/input", json: ["writer": self.writer, "sequence": sequence, "data": bytes.base64EncodedString()], quiet: true)
                    try Task.checkCancellation()
                    guard generation == self.generation else { return }
                    self.inputSequence = sequence
                    self.inputs.acknowledge()
                    reconnectAttempts = 0
                    self.didConnect()
                } catch {
                    if Task.isCancelled || generation != self.generation { return }
                    if let api = error as? DaemonHTTPError, (400..<500).contains(api.status), ![408, 425, 429].contains(api.status) {
                        // Keep both the frozen request and later typing. A rejected
                        // or partially written chunk must never be reassigned a new
                        // receipt, silently discarded, or sent to a fresh shell.
                        self.inputFailure = api.localizedDescription
                        self.connectionState = .failed(api.localizedDescription)
                        return
                    }
                    self.connectionState = .reconnecting
                    // Retry exactly this input; the daemon returns its original receipt.
                    let delay = 250 * (1 << min(reconnectAttempts, 3))
                    reconnectAttempts = min(3, reconnectAttempts + 1)
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                }
            }
        }
    }
    func resize(cols: Int, rows: Int) {
        columns = min(512, max(2, cols)); self.rows = min(256, max(2, rows))
        scheduleResize()
    }
    private func scheduleResize() {
        guard opened, attached, running, resizeTask == nil,
              appliedColumns != columns || appliedRows != rows else { return }
        let generation = self.generation
        resizeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { self.resizeTask = nil } }
            do {
                while self.attached, self.running, generation == self.generation {
                    try await Task.sleep(for: .milliseconds(80))
                    try Task.checkCancellation()
                    let columns = self.columns, rows = self.rows
                    if self.appliedColumns == columns && self.appliedRows == rows { return }
                    _ = try await self.http.run("PUT", self.path + "/size", json: ["columns": columns, "rows": rows], quiet: true)
                    try Task.checkCancellation()
                    guard generation == self.generation else { return }
                    self.appliedColumns = columns; self.appliedRows = rows
                }
            } catch { /* Reconnection applies the latest dimensions again. */ }
        }
    }
    func stop() {
        attached = false; generation += 1
        feedTask?.cancel(); feedTask = nil; inputTask?.cancel(); inputTask = nil; resizeTask?.cancel(); resizeTask = nil
        onOutput = nil
        onConnectionChange = nil
    }
    func kill() {
        stop()
        running = false
        closeTerminal(terminalId)
    }
    func retryConnection() {
        guard attached, running else { return }
        generation += 1
        feedTask?.cancel(); feedTask = nil
        inputTask?.cancel(); inputTask = nil
        resizeTask?.cancel(); resizeTask = nil
        inputFailure = nil
        feedFailure = nil
        attached = false
        start()
    }
    private var path: String { "/workspace/terminals/\(terminalId)" }
    private func apply(_ state: DaemonTerminalState) {
        running = state.running
        appliedColumns = state.columns; appliedRows = state.rows
    }
    private func didConnect() {
        connectionState = (inputFailure ?? feedFailure).map(TerminalConnectionState.failed) ?? .connected
    }
    deinit { feedTask?.cancel(); inputTask?.cancel(); resizeTask?.cancel() }
}
