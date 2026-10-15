import Foundation

/// Session-only freshness for shared read models. Persisted values still need a first check after
/// launch. Invalidating during a request prevents that older request from renewing the cache.
struct RefreshState {
    private(set) var revision = 0
    private var checkedAt: Date?
    private var succeeded = false

    func isFresh(at now: Date, maxAge: TimeInterval = 60) -> Bool {
        guard let checkedAt else { return false }
        let age = now.timeIntervalSince(checkedAt)
        // Failed checks are never considered healthy; a short cooldown only prevents navigation
        // from hammering an unavailable workspace. Explicit refresh always bypasses this gate.
        return age >= 0 && age < (succeeded ? maxAge : 10)
    }

    mutating func finish(success: Bool, at now: Date, revision: Int) {
        guard revision == self.revision else { return }
        checkedAt = now
        succeeded = success
    }

    mutating func invalidate() {
        revision &+= 1
        checkedAt = nil
    }
}
