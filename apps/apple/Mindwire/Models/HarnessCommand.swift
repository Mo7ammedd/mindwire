import Foundation

struct DaemonHarnessCommand: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let label: String
    let kind: String
    var description: String? = nil
    var aliases: [String]? = nil
    var argumentHint: String? = nil
    var acceptsArguments: Bool? = nil
    var settingCanons: [String]? = nil
    var requiresIdle: Bool? = nil
    var requiresSession: Bool? = nil

    var isSupported: Bool { ["settings", "compact", "prompt", "new_chat", "history", "rename"].contains(kind) }
    func matches(_ value: String) -> Bool { name == value || aliases?.contains(value) == true }
    func matchesSearch(_ value: String) -> Bool {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return query.isEmpty || ([name, label, description ?? ""] + (aliases ?? [])).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct DaemonCommandCatalog: Codable, Hashable {
    var commands: [DaemonHarnessCommand] = []
    var warning: String? = nil
}

struct DaemonCommandInvocation: Codable, Hashable {
    let name: String
    var arguments: String = ""
    var text: String { "/" + name + (arguments.isEmpty ? "" : " " + arguments) }

    static func parse(_ text: String) -> Self? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/"), value.count > 1 else { return nil }
        let pieces = value.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = pieces.first, first.count <= 200, first.first != "_",
              first.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 46, 58].contains($0) }) else { return nil }
        return .init(name: String(first), arguments: pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }

    static func query(_ text: String) -> String? {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return nil }
        return String(text.dropFirst())
    }
}
