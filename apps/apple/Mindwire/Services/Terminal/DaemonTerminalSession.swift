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
    private let channel: ComputerDaemonChannel
    private let workdir: String?
    private var closing: [Task<Void, Never>] = []
    init(computer: PairedComputer, workdir: String?, network: ComputerNetworkMonitor = .shared) {
        channel = ComputerDaemonChannel(computer: computer, network: network); self.workdir = workdir
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
        let closing = self.closing, channel = self.channel
        Task { for task in closing { await task.value }; await channel.close() }
    }
}

/// One daemon-owned PTY. All mutable state is on the main queue; HTTP/SSE suspend
/// off it. Keystrokes are serialized and retried with the same receipt ID.
final class DaemonTerminalSession: TerminalSession {
    var onOutput: ((Data) -> Void)?
    let handlesDeviceQueries = true
    private let channel: ComputerDaemonChannel
    private var http: DaemonHTTP { DaemonHTTP(channel: channel, agentType: "") }
    private let workdir: String?
    private var terminalId: String
    private var writer = UUID().uuidString
    private var inputSequence: UInt64 = 0
    private var cursor: UInt64 = 0
    private var columns = 80, rows = 24
    private var opened: Bool
    private var recoverExisting: Bool
    private var running = true
    private var attached = false
    private var generation = 0
    private var inputs: [Data] = []
    private var inputBytes = 0
    private var feedTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private let closeTerminal: (String) -> Void

    init(channel: ComputerDaemonChannel, state: DaemonTerminalState? = nil, workdir: String?, recoverExisting: Bool = false,
         closeTerminal: @escaping (String) -> Void) {
        self.channel = channel; self.workdir = workdir
        terminalId = state?.id ?? UUID().uuidString
        opened = state != nil; running = state?.running ?? true; self.recoverExisting = recoverExisting
        self.closeTerminal = closeTerminal
    }

    func start() {
        guard !attached else { return }; attached = true
        generation += 1
        let generation = self.generation
        feedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var failed = false
            while !Task.isCancelled, self.attached, generation == self.generation {
                do {
                    if self.recoverExisting {
                        let query = self.workdir.map { "?directory=\(self.http.encQuery($0))" } ?? ""
                        let states: [DaemonTerminalState] = try await self.http.decode("GET", "/workspace/terminals\(query)", quiet: true)
                        try Task.checkCancellation()
                        guard generation == self.generation else { return }
                        if let state = states.first(where: \.running) ?? states.first {
                            self.terminalId = state.id; self.opened = true; self.running = state.running
                        }
                        self.recoverExisting = false
                    }
                    if !self.opened {
                        let state: DaemonTerminalState = try await self.http.decode("POST", "/workspace/terminals", json: [
                            "id": self.terminalId, "directory": self.workdir ?? "", "columns": self.columns, "rows": self.rows
                        ], quiet: true)
                        try Task.checkCancellation()
                        guard generation == self.generation else { return }
                        self.opened = true; self.running = state.running
                    }
                    self.flushInput()
                    if self.running { self.scheduleResize() }
                    let events = try await self.channel.stream(method: "GET", path: self.path + "/events?after=\(self.cursor)", jsonBody: nil)
                    for try await data in events {
                        try Task.checkCancellation()
                        guard generation == self.generation else { return }
                        let event = try JSONDecoder().decode(DaemonTerminalEvent.self, from: data)
                        guard event.kind == "reset" || event.sequence > self.cursor else { continue }
                        guard ["output", "reset", "exit"].contains(event.kind) else { throw BackendError.message("Unknown terminal update.") }
                        if let bytes = event.data { self.onOutput?(bytes) }
                        self.cursor = event.sequence
                        if let state = event.state { self.running = state.running }
                        if event.kind == "exit" { self.running = false; return }
                        failed = false
                    }
                    if !self.running { return }
                    throw ComputerConnectionError.unreachable
                } catch {
                    if Task.isCancelled || !self.attached || generation != self.generation { return }
                    if let api = error as? DaemonHTTPError, [400, 401, 403, 404, 409].contains(api.status) {
                        self.message(api.localizedDescription); return
                    }
                    if !failed { self.message("Connection interrupted. Reconnecting…"); failed = true }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }

    func send(_ data: Data) {
        guard attached, running, !data.isEmpty else { return }
        guard inputBytes + data.count <= 256 * 1024 else { message("Input is waiting for the computer. Try again after it reconnects."); return }
        for start in stride(from: 0, to: data.count, by: 65_536) {
            inputs.append(data.subdata(in: start..<min(data.count, start + 65_536)))
        }
        inputBytes += data.count
        flushInput()
    }
    private func flushInput() {
        guard opened, attached, running, inputTask == nil, !inputs.isEmpty else { return }
        let generation = self.generation
        inputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { self.inputTask = nil } }
            while !Task.isCancelled, self.attached, self.running, generation == self.generation, let bytes = self.inputs.first {
                let sequence = self.inputSequence + 1
                do {
                    _ = try await self.http.run("POST", self.path + "/input", json: ["writer": self.writer, "sequence": sequence, "data": bytes.base64EncodedString()], quiet: true)
                    try Task.checkCancellation()
                    guard generation == self.generation else { return }
                    self.inputSequence = sequence
                    self.inputBytes -= bytes.count
                    self.inputs.removeFirst()
                } catch {
                    if Task.isCancelled || generation != self.generation { return }
                    if let api = error as? DaemonHTTPError, (400..<500).contains(api.status) {
                        self.inputs = []; self.inputBytes = 0
                        // A rejected/partial write is never replayed. New keystrokes
                        // start a new writer so an old failure cannot poison the queue.
                        self.writer = UUID().uuidString; self.inputSequence = 0
                        self.message(api.localizedDescription); return
                    }
                    // Retry exactly this input; the daemon returns its original receipt.
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }
    func resize(cols: Int, rows: Int) {
        columns = min(512, max(2, cols)); self.rows = min(256, max(2, rows))
        scheduleResize()
    }
    private func scheduleResize() {
        guard opened, attached, running else { return }
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
                guard let self else { return }
                _ = try await self.http.run("PUT", self.path + "/size", json: ["columns": self.columns, "rows": self.rows], quiet: true)
            } catch { /* Reconnection applies the latest dimensions again. */ }
        }
    }
    func stop() {
        attached = false; generation += 1
        feedTask?.cancel(); feedTask = nil; inputTask?.cancel(); inputTask = nil; resizeTask?.cancel(); resizeTask = nil
        onOutput = nil
    }
    func kill() {
        stop()
        closeTerminal(terminalId)
    }
    private var path: String { "/workspace/terminals/\(terminalId)" }
    private func message(_ text: String) {
        // Escape control characters in error text before feeding it to a terminal emulator.
        let text = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        onOutput?(Data("\r\n\u{1b}[90m\(text)\u{1b}[0m\r\n".utf8))
    }
    deinit { feedTask?.cancel(); inputTask?.cancel(); resizeTask?.cancel() }
}
