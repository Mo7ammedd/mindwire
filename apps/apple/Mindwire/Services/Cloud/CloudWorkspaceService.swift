import Foundation
import OblienKit

/// `WorkspaceService` for Oblien Cloud, implemented on top of `OblienKit`. Management calls
/// (resources/status/power/ports) go through the workspace handle; files/exec/terminal go
/// through a cached `RuntimeClient` (which owns the gateway-JWT lifecycle). This adapter just
/// maps the SDK's types to the app's `Ports` types.
actor CloudWorkspaceService: WorkspaceService {
    nonisolated let capabilities: WorkspaceCapabilities
    nonisolated let management: WorkspaceManagementService?
    nonisolated let daemonSupervisor: (any DaemonSupervisor)?
    private let workspaceId: String?
    private var runtimeClient: RuntimeClient?

    init(workspaceId: String?) {
        self.workspaceId = workspaceId
        self.capabilities = workspaceId == nil ? .none : .full
        self.management = workspaceId.map { CloudWorkspaceManagement(workspaceId: $0) }
        self.daemonSupervisor = workspaceId.map { CloudDaemonSupervisor(workspaceId: $0) }
    }

    private func handle() throws -> WorkspaceHandle {
        guard let workspaceId else {
            throw BackendError.notImplemented("cloud workspace: no workspace provisioned for this agent")
        }
        return MindwireCloud.workspace(workspaceId)
    }

    private func runtime() async throws -> RuntimeClient {
        if let runtimeClient { return runtimeClient }
        let rt = try await handle().runtime()
        runtimeClient = rt
        return rt
    }

    // MARK: - Management

    func status() async throws -> WorkspaceStatus {
        try await WorkspaceStatus(cloud: handle().get())
    }

    func getResources() async throws -> WorkspaceResources {
        let r = try await handle().resources.get()
        return WorkspaceResources(cpus: r.cpus ?? 0, memoryMb: r.memoryMb ?? 0, diskMb: r.diskSizeMb ?? 0)
    }

    func updateResources(_ patch: WorkspaceResourcePatch) async throws -> WorkspaceResources {
        let result = try await handle().resources.update(
            OblienKit.ResourcePatch(cpus: patch.cpus, memoryMb: patch.memoryMb, diskSizeMb: patch.diskMb, apply: patch.apply)
        )
        let u = result.updated
        return WorkspaceResources(cpus: u.cpus ?? 0, memoryMb: u.memoryMb ?? 0, diskMb: u.diskSizeMb ?? 0)
    }

    func power(_ action: PowerAction) async throws {
        let ws = try handle()
        // A restarted VM has a new runtime connection/token lifecycle.
        runtimeClient = nil
        switch action {
        case .start: try await ws.wake()
        case .stop: try await ws.stop()
        case .restart: try await ws.restart()
        }
    }

    func listPorts() async throws -> [Mindwire.ExposedPort] {
        let ports = try await handle().publicAccess.list()
        return ports.map { Mindwire.ExposedPort(port: $0.port, url: $0.url ?? "", label: $0.label, slug: $0.slug) }
    }

    func exposePort(_ input: ExposePortInput) async throws -> Mindwire.ExposedPort {
        let p = try await handle().publicAccess.expose(port: input.port, label: input.label, slug: input.slug)
        return Mindwire.ExposedPort(port: p.port, url: p.url ?? "", label: p.label, slug: p.slug)
    }

    func unexposePort(_ port: Int) async throws {
        try await handle().publicAccess.revoke(port: port)
    }

    // MARK: - Runtime

    // File ops use the native runtime files API (`rt.files.*`). An earlier version routed these
    // through the shell as a workaround for the API reading a stale filesystem view; that's fixed —
    // the API now lists everything written by clone/terminal/exec. Self-hosted (no runtime API) and
    // exec/git stay on the shell.

    func listFiles(_ path: String) async throws -> [Mindwire.FileEntry] {
        let dir = path.isEmpty ? "/" : path
        // Show EVERYTHING (incl. gitignored) and dim the ignored ones VS Code-style. The displayed
        // list uses use_gitignore=false; a second light probe with use_gitignore=true returns only the
        // non-ignored paths, so (all − visible) is exactly what `.gitignore` covers. `.git` is excluded
        // from both via ignore_patterns. The runtime is authoritative for nested/negation semantics.
        let rt = try await runtime()
        async let allR = rt.files.list(OblienKit.FileListParams(path: dir, useGitignore: false, ignorePatterns: ".git"))
        async let visR = rt.files.list(OblienKit.FileListParams(path: dir, useGitignore: true, ignorePatterns: ".git", light: true))
        let (all, vis) = try await (allR, visR)
        let visible = Set(vis.entries.map(\.path))
        return all.entries.map {
            Mindwire.FileEntry(name: $0.name, path: $0.path, type: $0.isDirectory ? .dir : .file,
                                  size: $0.size, modifiedAt: $0.modified, isIgnored: !visible.contains($0.path))
        }
    }

    func searchFiles(_ query: String, in path: String) async throws -> [Mindwire.FileEntry] {
        // Native filename search; `.git` excluded, hidden files included to match the browser.
        let dir = path.isEmpty ? "/" : path
        let rel = try await runtime().search.files(query, path: dir, ignorePatterns: ".git", includeHidden: true)
        return rel.prefix(300).map { r in
            let full = r.hasPrefix("/") ? r : (dir.hasSuffix("/") ? "\(dir)\(r)" : "\(dir)/\(r)")
            return Mindwire.FileEntry(name: (full as NSString).lastPathComponent, path: full,
                                         type: .file, size: nil, modifiedAt: nil)
        }
    }

    func readFile(_ path: String) async throws -> FileContent {
        do {
            let r = try await runtime().files.read(path: path)
            APILog.note("files ✓ read \(path) (\(r.content.utf8.count)b)")
            return FileContent(path: path, content: r.content, size: r.size)
        } catch {
            APILog.note("files ✗ read \(path): \(error.localizedDescription)")
            throw error
        }
    }

    func writeFile(_ path: String, content: String) async throws {
        _ = try await runtime().files.write(fullPath: path, content: content, createDirs: true)
    }

    func deleteFile(_ path: String) async throws {
        try await runtime().files.delete(path: path)
    }

    func exec(_ cmd: [String]) async throws -> ExecResult {
        // Foreground mode waits for completion instead of accepting a background task.
        // The command receipt supplies its actual exit status when the runtime's task
        // tracker reports a timeout after a completed command. Never replay an uncertain write.
        try await Self.execute(cmd, runtime: runtime(), timeout: 300)
    }

    private static func execute(_ command: [String], runtime: RuntimeClient, timeout: Int) async throws -> ExecResult {
        let request = try CloudExecCommand(command)
        let task = try await runtime.exec.run(request.wrappedArguments, timeoutSeconds: timeout, execMode: .foreground)
        return try request.decode(ExecResult(exitCode: task.exitCode, stdout: task.stdout ?? "", stderr: task.stderr ?? ""))
    }

    /// Run a command with **foreground** exec — blocks until the process exits and returns the full
    /// stdout/stderr + real exit code. This is the execution mode proven to run clones on the runtime
    /// (public clones worked with it); background tasks behaved differently. Output arrives at the
    /// end (not live). `workspaceId` is an immutable `let` → `nonisolated`.
    nonisolated func execStream(_ cmd: [String]) -> AsyncThrowingStream<ExecEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let workspaceId else { continuation.finish(); return }
            let task = Task {
                do {
                    let rt = try await MindwireCloud.workspace(workspaceId).runtime()
                    let result = try await Self.execute(cmd, runtime: rt, timeout: 600)
                    let combined = [result.stdout, result.stderr]
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    if !combined.isEmpty { continuation.yield(.output(Data(combined.utf8))) }
                    continuation.yield(.exit(result.exitCode))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func terminalEndpoint() async throws -> WorkspaceTerminalEndpoint {
        guard let workspaceId else { throw BackendError.notImplemented("Choose a Cloud Computer first.") }
        let rt = try await runtime()
        let token = try await rt.token()
        let wsURL = rt.websocketURL().absoluteString
        let createURL = MindwireCloud.client(for: workspaceId).config.runtimeURL.absoluteString + "/terminals"
        return WorkspaceTerminalEndpoint(wsUrl: wsURL, createUrl: createURL, token: token, protocol: "oblien")
    }

    /// Current VM stats from the **management** API (`GET /workspace/:id/stats`) via the SDK's
    /// `MetricsAPI` — an instant first value.
    func stats() async throws -> WorkspaceStatsSample? {
        guard let workspaceId else { return nil }
        return Self.sample(from: try await MindwireCloud.workspace(workspaceId).metrics.stats())
    }

    /// Live VM stats over the SDK's SSE stream (`/workspace/:id/stats/stream`). `workspaceId` is an
    /// immutable `let`, so this is `nonisolated` (the stream does its own async work).
    nonisolated func statsStream() -> AsyncThrowingStream<WorkspaceStatsSample, Error> {
        AsyncThrowingStream { continuation in
            guard let workspaceId else { continuation.finish(); return }
            let task = Task {
                do {
                    APILog.note("SSE stats: opening stream for \(workspaceId)")
                    for try await s in MindwireCloud.workspace(workspaceId).metrics.statsStream() {
                        // Temporary diagnostic — confirms what the SSE actually decodes (toggle off
                        // later; APILog is DEBUG-only). cpu/mem%/disk% + cumulative net bytes.
                        APILog.note("SSE stats: cpu=\(s.cpuUsage ?? -1) mem=\(s.memoryUsedMB ?? -1)/\(s.memoryTotalMB ?? -1) diskPct=\(s.guestDiskUsedPct ?? -1) netIn=\(s.networkInBytes ?? -1) netOut=\(s.networkOutBytes ?? -1)")
                        continuation.yield(Self.sample(from: s))
                    }
                    APILog.note("SSE stats: stream closed")
                    continuation.finish()
                } catch {
                    APILog.note("SSE stats: error \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Map the SDK `Stats` to the app sample. Percentages computed from used/total when available
    /// (robust to units); `cpuUsage` is treated as a 0–100 percent.
    private static func sample(from s: Stats) -> WorkspaceStatsSample {
        let memUsed = s.memoryUsedMB ?? 0
        let memTotal = s.memoryTotalMB ?? 0
        let memPercent = memTotal > 0 ? (memUsed / memTotal * 100) : (s.memoryUsage ?? 0)
        // Disk: the runtime reports a direct percent; fall back to the byte ratio.
        let diskPercent: Double = {
            if let pct = s.guestDiskUsedPct { return pct }
            let used = s.guestDiskUsedBytes ?? 0, total = s.guestDiskTotalBytes ?? 0
            return total > 0 ? used / total * 100 : 0
        }()
        // Traffic: cumulative in+out bytes (the model derives a rate from deltas).
        let net: Double? = (s.networkInBytes == nil && s.networkOutBytes == nil)
            ? nil : (s.networkInBytes ?? 0) + (s.networkOutBytes ?? 0)
        return WorkspaceStatsSample(
            cpuPercent: min(max(s.cpuUsage ?? 0, 0), 100),
            memoryPercent: min(max(memPercent, 0), 100),
            memoryUsedMb: memUsed,
            memoryTotalMb: memTotal,
            diskPercent: min(max(diskPercent, 0), 100),
            networkTotalBytes: net
        )
    }
}
