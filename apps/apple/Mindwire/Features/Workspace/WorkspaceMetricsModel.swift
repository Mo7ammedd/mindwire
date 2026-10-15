import Foundation

/// Subscribes to a workspace's live stats stream and keeps the latest sample plus a rolling history
/// for charts. Backed by the management metrics stream (cloud only; self-hosted yields nothing).
@Observable
@MainActor
final class WorkspaceMetricsModel {
    enum Phase { case connecting, live, unavailable }

    private(set) var phase: Phase = .connecting
    private(set) var latest: WorkspaceStatsSample?
    private(set) var history: [WorkspaceStatsSample] = []
    /// Derived network throughput (KB/s) from consecutive cumulative byte counters. nil = the
    /// runtime doesn't report network counters.
    private(set) var trafficKbps: Double?

    private let workspace: WorkspaceService
    private var task: Task<Void, Never>?
    private let maxSamples = 60
    private var lastBytes: Double?
    private var lastBytesAt: Date?

    init(workspace: WorkspaceService) { self.workspace = workspace }

    func start() {
        guard task == nil else { return }
        phase = latest == nil ? .connecting : .live
        task = Task { [weak self] in
            guard let self else { return }
            // Instant first value (the SSE first push can lag a beat).
            if let sample = try? await self.workspace.stats() { self.ingest(sample) }
            // Live SSE stream, reconnecting on drop until stopped.
            while !Task.isCancelled {
                do {
                    for try await sample in self.workspace.statsStream() {
                        if Task.isCancelled { return }
                        self.ingest(sample)
                    }
                } catch {
                    APILog.note("stats stream error: \(error.localizedDescription)")
                }
                if Task.isCancelled { return }
                if self.history.isEmpty { self.phase = .unavailable }
                try? await Task.sleep(for: .seconds(3)) // brief backoff, then reconnect
            }
        }
    }

    /// Re-arm after an `unavailable` state.
    func retry() {
        stop()
        phase = .connecting
        start()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func ingest(_ sample: WorkspaceStatsSample) {
        latest = sample
        history.append(sample)
        if history.count > maxSamples { history.removeFirst(history.count - maxSamples) }
        phase = .live
        updateTraffic(sample)
    }

    /// Throughput = Δbytes / Δt between consecutive cumulative counters.
    private func updateTraffic(_ sample: WorkspaceStatsSample) {
        guard let bytes = sample.networkTotalBytes else { return }
        let now = Date()
        if let last = lastBytes, let at = lastBytesAt {
            let dt = now.timeIntervalSince(at)
            if dt > 0 { trafficKbps = max(0, (bytes - last) / dt / 1024) }
        }
        lastBytes = bytes
        lastBytesAt = now
    }
}
