import Foundation

/// Bounded, in-memory keyboard input. Freeze the active chunk until its receipt
/// arrives; new typing coalesces behind it without changing a retry's payload.
struct TerminalInputBuffer {
    private var waiting = Data()
    private var inFlight: Data?
    private let maximumBytes = 256 * 1024
    private let chunkBytes = 16 * 1024

    var isEmpty: Bool { inFlight == nil && waiting.isEmpty }

    mutating func append(_ bytes: Data) -> Bool {
        guard bytes.count <= maximumBytes - waiting.count - (inFlight?.count ?? 0) else { return false }
        waiting.append(bytes)
        return true
    }

    mutating func next() -> Data? {
        if let inFlight { return inFlight }
        guard !waiting.isEmpty else { return nil }
        let bytes = Data(waiting.prefix(chunkBytes))
        waiting.removeFirst(bytes.count)
        inFlight = bytes
        return bytes
    }

    mutating func acknowledge() { inFlight = nil }
}
