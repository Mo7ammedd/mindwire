import Foundation

/// One recovery interval survives individual retries. A successful display or
/// heartbeat ends it; intermediate connection stages never restart its clock.
struct DesktopRecovery {
    static let grace: TimeInterval = 10
    private(set) var startedAt: TimeInterval?
    private(set) var timedOut = false
    var active: Bool { startedAt != nil }

    @discardableResult mutating func begin(at time: TimeInterval) -> Bool {
        guard startedAt == nil else { return false }
        startedAt = time
        return true
    }
    mutating func advance(to time: TimeInterval) {
        if let startedAt, time - startedAt >= Self.grace { timedOut = true }
    }
    mutating func finish() { self = .init() }
}

/// Retry a delayed heartbeat within the 15-second lease instead of tearing down
/// a healthy viewer on one failure. Each input still validates its controller.
struct DesktopHeartbeat {
    private(set) var failedAt: TimeInterval?
    mutating func failed(at time: TimeInterval) { if failedAt == nil { failedAt = time } }
    mutating func recovered() { failedAt = nil }
    func exhausted(at time: TimeInterval) -> Bool { failedAt.map { time - $0 >= 8 } ?? false }
}

@MainActor
func desktopDeadline<T: Sendable>(_ seconds: Double, operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DesktopProblem(code: "timeout", message: "The desktop connection is taking too long.")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
