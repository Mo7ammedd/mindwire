import Foundation

/// Input acknowledgement and visible-frame acknowledgement are different. Only
/// a frame requested after dispatch can confirm the view has caught up. This
/// drives status and video refresh, never pointer movement or input acceptance.
struct DesktopInputProgress {
    static let grace: TimeInterval = 0.65
    private var inFlightAt: TimeInterval?
    private var observations: [TimeInterval] = []
    private var displayedAfter: TimeInterval = 0
    private var refreshedThrough: TimeInterval = 0
    var pending: Bool { inFlightAt != nil || !observations.isEmpty }

    mutating func began(at time: TimeInterval) { inFlightAt = time }
    mutating func acknowledged(at time: TimeInterval, changesDisplay: Bool) {
        inFlightAt = nil
        if changesDisplay, time > displayedAfter { observations.append(time) }
    }
    mutating func displayed(requestedAt time: TimeInterval) {
        displayedAfter = max(displayedAfter, time)
        observations.removeAll { $0 <= displayedAfter }
    }
    mutating func needsRefresh(at time: TimeInterval) -> Bool {
        guard let first = observations.first, first > refreshedThrough, time - first >= 0.12 else { return false }
        // The changed pixels may already have arrived before the HTTP receipt.
        // Wake a now-static incremental stream before the input stall deadline,
        // once for this batch; normal streaming confirms it without extra work.
        refreshedThrough = observations.last ?? first
        return true
    }
    func stalled(at time: TimeInterval) -> Bool {
        [inFlightAt, observations.first].compactMap { $0 }.contains { time - $0 >= Self.grace }
    }
    func displayStalled(at time: TimeInterval) -> Bool {
        observations.first.map { time - $0 >= 4 } ?? false
    }
    mutating func reset() { self = .init() }
}

extension DesktopInput {
    var changesDisplay: Bool {
        switch kind {
        case "pointer": (buttons ?? 0) != 0
        case "release", "clipboard_read", "clipboard_write": false
        default: true
        }
    }
    var releasesButtons: Bool { kind == "release" || kind == "pointer" && (buttons ?? 0) == 0 }
}
