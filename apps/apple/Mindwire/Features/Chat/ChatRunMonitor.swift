import Foundation

/// A connection ending is not a completed turn. Keep reconnecting from the last event,
/// and independently check the daemon's run state in case a connection hangs at completion.
@MainActor
enum ChatRunMonitor {
    private enum Update {
        case event(Int, DaemonEvent)
        case closed(Int)
        case unsupported(Int)
        case run(DaemonRun)
    }

    static func follow(openStream: @escaping () async throws -> AsyncThrowingStream<DaemonEvent, Error>?,
                       getRun: @escaping () async throws -> DaemonRun,
                       onEvent: @escaping (DaemonEvent) -> Void,
                       wait: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async throws -> DaemonRun {
        try await follow(openStreamAfter: { _ in try await openStream() }, getRun: getRun,
                         onEvent: onEvent, wait: wait)
    }

    static func follow(openStreamAfter: @escaping (Int?) async throws -> AsyncThrowingStream<DaemonEvent, Error>?,
                       getRun: @escaping () async throws -> DaemonRun,
                       getSnapshot: (() async throws -> DaemonRunSnapshot?)? = nil,
                       after initialSequence: Int? = nil,
                       restore: Bool = false,
                       onEvent: @escaping (DaemonEvent) -> Void,
                       onSnapshot: @escaping (DaemonRunSnapshot) -> Void = { _ in },
                       onConnectionChange: @escaping (Bool) -> Void = { _ in },
                       checkInterval: Duration = .seconds(3),
                       quietInterval: Duration = .seconds(6),
                       wait: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async throws -> DaemonRun {
        let (updates, continuation) = AsyncStream<Update>.makeStream()
        var reader: Task<Void, Never>?
        var connection = 0
        // A retained chat supplies the cursor belonging to its materialized live turn.
        // Cold/evicted chats still hydrate a snapshot before opening the stream.
        var sequence = initialSequence.flatMap { $0 >= 0 ? $0 : nil }
        var deliveredLegacy = 0
        var position = 0
        var snapshotsSupported = getSnapshot != nil
        var lastProgress = ContinuousClock.now

        func synchronize() async -> DaemonRun? {
            guard snapshotsSupported, let getSnapshot else { return nil }
            do {
                guard let snapshot = try await getSnapshot() else {
                    snapshotsSupported = false
                    return nil
                }
                try Task.checkCancellation()
                if sequence == nil || snapshot.sequence >= (sequence ?? 0) {
                    sequence = snapshot.sequence
                    onSnapshot(snapshot)
                }
                return snapshot.run
            } catch { return nil }
        }

        func connect() {
            connection += 1
            let id = connection, after = sequence
            position = 0
            reader = Task {
                do {
                    let opened = try await openStreamAfter(after)
                    try Task.checkCancellation()
                    guard let stream = opened else {
                        continuation.yield(.unsupported(id))
                        return
                    }
                    for try await event in stream {
                        try Task.checkCancellation()
                        continuation.yield(.event(id, event))
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                continuation.yield(.closed(id))
            }
        }

        let status = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: checkInterval)
                    let run = try await getRun()
                    try Task.checkCancellation()
                    continuation.yield(.run(run))
                    if run.status != .running { return }
                } catch {
                    if Task.isCancelled { return }
                    // An unreachable status endpoint does not mean that the run stopped.
                }
            }
        }
        defer {
            reader?.cancel()
            status.cancel()
            continuation.finish()
        }
        if restore, sequence == nil, let run = await synchronize(), run.status != .running { return run }
        try Task.checkCancellation()
        connect()

        for await update in updates {
            try Task.checkCancellation()
            switch update {
            case .event(let id, let event):
                guard id == connection else { continue }
                onConnectionChange(true)
                if event.type == .status, event.meta?["stream"] != nil {
                    onEvent(event)
                    continue
                }
                if let next = event.sequence, next > 0 {
                    guard next > (sequence ?? 0) else { continue }
                    // Never append across a gap. Recover a checkpoint first, since a
                    // truncated buffer cannot supply the missing suffix on another retry.
                    if next != (sequence ?? 0) + 1 {
                        reader?.cancel()
                        onConnectionChange(false)
                        if let run = await synchronize(), run.status != .running { return run }
                        try await wait()
                        try Task.checkCancellation()
                        connect()
                        continue
                    }
                    sequence = next
                } else {
                    // Compatibility with daemons that replay the full buffer without cursors.
                    position += 1
                    guard position > deliveredLegacy else { continue }
                    deliveredLegacy = position
                }
                lastProgress = .now
                onEvent(event)
            case .closed(let id):
                guard id == connection else { continue }
                if let run = try? await getRun(), run.status != .running {
                    _ = await synchronize()
                    return run
                }
                onConnectionChange(false)
                try await wait()
                try Task.checkCancellation()
                connect()
            case .unsupported(let id):
                guard id == connection else { continue }
                onConnectionChange(false)
                // Poll snapshots on transports that cannot stream; keep showing partial output.
                if let run = await synchronize(), run.status != .running { return run }
                if !snapshotsSupported {
                    status.cancel()
                    return try await poll(getRun: getRun, wait: wait)
                }
            case .run(let run):
                if run.status != .running {
                    _ = await synchronize()
                    return run
                }
                if lastProgress.duration(to: .now) >= quietInterval {
                    let before = sequence
                    let latest = await synchronize()
                    if let latest, latest.status != .running { return latest }
                    if sequence != before {
                        reader?.cancel()
                        onConnectionChange(false)
                        connect()
                    }
                    lastProgress = .now
                }
            }
        }
        throw CancellationError()
    }

    static func poll(getRun: () async throws -> DaemonRun,
                     wait: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async throws -> DaemonRun {
        for _ in 0..<1800 {
            try Task.checkCancellation()
            let run = try await getRun()
            if run.status != .running { return run }
            try await wait()
        }
        throw URLError(.timedOut)
    }
}
