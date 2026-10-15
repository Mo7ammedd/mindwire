import Foundation

struct DaemonMessagePage: Decodable {
    let messages: [DaemonMessage]
    let hasMore: Bool
    let before: String?
    var revision: String? = nil
    var notModified: Bool? = nil
    var byteCount = 0

    enum CodingKeys: String, CodingKey { case messages, hasMore, before, revision, notModified }
}

enum ChatHistoryPaging {
    // Also bounds the legacy array response from services predating byte-budgeted pages.
    static let limit = 12
    static let maxBytes = 1_024 * 1_024

    /// Preserve previously loaded older pages when a refreshed tail overlaps them. If it
    /// doesn't, replace the window so scroll-to-top can fetch the gap without skipping it.
    static func merging(_ newest: [DaemonMessage], into current: [DaemonMessage]) -> [DaemonMessage] {
        let ids = Set(newest.map(\.id))
        guard let overlap = current.firstIndex(where: { ids.contains($0.id) }) else { return newest }
        return Array(current[..<overlap]) + newest
    }
}
