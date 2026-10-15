import SwiftUI

/// The pressed row owns its menu payload. Keep the original content until the menu is opened so
/// scrolling/streaming does not serialize tool output, and never fall back to the parent turn.
struct ChatTranscriptSelection: Identifiable, Equatable {
    let id: ChatTranscriptRow.ID
    let content: ChatTranscriptRow.Content

    var text: String {
        switch content {
        case .user(let text), .text(let text): text
        case .part(let part): part.transcriptText
        case .commands(let parts, _): parts.map(\.transcriptText).joined(separator: "\n\n")
        case .status: ""
        }
    }

    var previewText: String {
        let snippet = text.prefix(1501)
        return snippet.count > 1500 ? String(snippet.prefix(1500)) + "…" : String(snippet)
    }
}

struct ChatTranscriptSelectionPreview: View {
    let selection: ChatTranscriptSelection

    var body: some View {
        Text(selection.previewText)
            .naturalChatDirection(selection.previewText, fillWidth: true)
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(Spacing.md)
            .frame(maxWidth: 360, alignment: .leading)
            .frame(maxHeight: 460, alignment: .top)
            .clipped()
    }
}

extension ChatTranscriptRow {
    var selection: ChatTranscriptSelection? {
        if case .status = content { return nil }
        return .init(id: id, content: content)
    }
}

private extension DaemonMessagePart {
    var transcriptText: String {
        switch kind {
        case .text, .thinking:
            return text ?? ""
        case .tool:
            guard let tool else { return text ?? "" }
            var sections: [String] = []
            if !tool.fileEdits.isEmpty {
                for edit in tool.fileEdits {
                    let diff = edit.unifiedDiff ?? edit.hunks.map { hunk in
                        let removed = hunk.old.isEmpty ? [] : hunk.old.components(separatedBy: "\n").map { "-" + $0 }
                        let added = hunk.new.isEmpty ? [] : hunk.new.components(separatedBy: "\n").map { "+" + $0 }
                        return (removed + added).joined(separator: "\n")
                    }.joined(separator: "\n")
                    sections.append(edit.path + "\n" + diff)
                }
            } else {
                if !tool.isShellCommand, let title = tool.action?.title ?? tool.name { sections.append(title) }
                if let input = tool.transcriptInputText { sections.append(input) }
            }
            if let output = tool.output, !output.isEmpty {
                sections.append(output)
            } else {
                if let output = tool.action?.shell?.stdout, !output.isEmpty { sections.append(output) }
                if let error = tool.action?.shell?.stderr, !error.isEmpty { sections.append(error) }
            }
            return sections.joined(separator: "\n\n")
        case .interaction:
            guard let interaction else { return text ?? "" }
            var sections = [interaction.title, interaction.detail].compactMap { $0 }
            sections += (interaction.items ?? []).map(\.content)
            sections += (interaction.options ?? []).map { optionText($0) }
            for question in interaction.questions ?? [] {
                sections.append(question.title)
                if let header = question.header { sections.append(header) }
                sections += (question.options ?? []).map { optionText($0) }
            }
            return sections.joined(separator: "\n\n")
        case .compaction:
            return compaction?.summary ?? t("chat.compacted")
        case .user:
            return input?.text ?? text ?? ""
        }
    }

    func optionText(_ option: DaemonInteractionOption) -> String {
        [option.label, option.description].compactMap { $0 }.joined(separator: " — ")
    }
}

extension DaemonToolCall {
    /// Shared by the disclosure and its menu: shell commands stay readable, other input keeps
    /// its complete JSON rather than an unrelated assistant summary.
    var transcriptInputText: String? {
        if isShellCommand, let command = shellCommandText { return command }
        guard let input else { return nil }
        if let text = input.string { return text }
        if let command = input["command"]?.string { return command }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(input)).map { String(decoding: $0, as: UTF8.self) }
    }
}
