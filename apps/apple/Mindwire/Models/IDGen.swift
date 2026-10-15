import Foundation

/// Mirrors the RN `newId()` — `base36(now)-base36(rand)`. Collision-tolerant, not cryptographic.
func newId() -> String {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let rand = Int.random(in: 0..<1_000_000_000)
    return String(now, radix: 36) + "-" + String(rand, radix: 36)
}

/// ISO-8601 timestamp for `createdAt` / `lastUsedAt` fields (matches `new Date().toISOString()`).
func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}
