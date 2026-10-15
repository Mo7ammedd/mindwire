import SwiftUI

/// Compact activity dates shared by conversations and repository rows.
enum RelativeTime {
    static func date(_ value: String) -> Date? {
        (try? Date(value, strategy: .iso8601.time(includingFractionalSeconds: true)))
            ?? (try? Date(value, strategy: .iso8601))
    }

    static func text(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let units: [(TimeInterval, String)] = [(31_536_000, "y"), (2_592_000, "mo"),
            (604_800, "w"), (86_400, "d"), (3_600, "h"), (60, "m")]
        guard let (duration, unit) = units.first(where: { seconds >= $0.0 }) else { return t("time.justNow") }
        return t("time.ago", ["value": "\(Int(seconds / duration))\(unit)"])
    }

    static func elapsed(_ start: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 3600 { return "\(seconds / 3600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}

struct RelativeTimestamp: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(RelativeTime.text(date, now: context.date))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(date.formatted(date: .abbreviated, time: .shortened))
        }
    }
}
