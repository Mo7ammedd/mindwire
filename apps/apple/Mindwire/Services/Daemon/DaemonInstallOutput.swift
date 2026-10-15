import Foundation

/// Reads the shared bootstrap's stage markers and curl's native percentage bar. SSH can
/// split a carriage-return-delimited progress line across any number of network packets.
struct DaemonInstallOutput {
    private var pending = Data()
    private var downloading = false
    private static let percentage = try! NSRegularExpression(pattern: #"^\s*#*\s*([0-9]{1,3}(?:\.[0-9]+)?)%\s*$"#)

    mutating func receive(_ data: Data) -> [DaemonInstallProgress] {
        pending.append(data)
        var result: [DaemonInstallProgress] = []
        while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            if line.contains("DAEMON_PROGRESS downloading") {
                downloading = true
                result.append(.downloading(nil))
            } else if line.contains("DAEMON_PROGRESS starting") {
                downloading = false
                result.append(.starting)
            } else if downloading,
                      let match = Self.percentage.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range(at: 1), in: line), let percent = Double(line[range]), percent <= 100 {
                result.append(.downloading(percent / 100))
            }
        }
        if pending.count > 4_096 { pending.removeFirst(pending.count - 4_096) }
        return result
    }
}
