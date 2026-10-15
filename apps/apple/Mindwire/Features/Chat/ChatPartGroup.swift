import Foundation

/// Presentation only: keep the daemon's ordered parts intact and group adjacent shell calls.
/// Source indexes are stable as a run grows and when older messages are prepended.
struct ChatPartGroup: Identifiable, Equatable {
    let startIndex: Int
    var parts: [DaemonMessagePart]
    let startsBlock: Bool

    var id: Int { startIndex }
    var isCommandGroup: Bool { parts.count > 1 }

    static func make(_ parts: [DaemonMessagePart]) -> [Self] {
        var groups: [Self] = []
        for (index, part) in parts.enumerated() {
            let previous = index > 0 ? parts[index - 1] : nil
            if part.isShellCommand, previous?.isShellCommand == true, !groups.isEmpty {
                groups[groups.count - 1].parts.append(part)
            } else {
                groups.append(.init(startIndex: index, parts: [part],
                                    startsBlock: previous.map { $0.kind != part.kind } ?? false))
            }
        }
        return groups
    }
}

extension DaemonMessagePart {
    var isShellCommand: Bool { kind == .tool && tool?.isShellCommand == true }

    /// A native result (including an empty result) settles a tool. A restored live run can still
    /// show activity without replaying animations or expanding its saved output.
    var hasPendingToolResult: Bool {
        kind == .tool && tool != nil && durationMs == nil && tool?.output == nil
            && tool?.isError == nil && tool?.action?.shell?.exitCode == nil
    }
}

extension DaemonToolCall {
    var isShellCommand: Bool {
        guard action?.surface == nil else { return false }
        if let action { return action.kind == "shell" }
        let name = name?.split(separator: ".").last?.lowercased() ?? ""
        return ["bash", "shell", "exec_command", "shell_command"].contains(name)
    }

    var shellCommandText: String? {
        for value in [action?.shell?.command, input?["command"]?.string,
                      input?["cmd"]?.string, input?.string] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }
}
