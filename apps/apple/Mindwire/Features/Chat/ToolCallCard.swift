import SwiftUI

/// A generic collapsible card for a non-edit tool call (Bash / Read / Grep / Glob / WebFetch / … ).
/// Collapsed: tool icon + name + a one-line input summary (+ duration or error). Tap to expand the
/// full input and output. Edits (Edit/Write/MultiEdit) render as `ToolDiffCard` instead (see
/// `TurnPartsView`). Same card shell as `ToolDiffCard` so the two read as one family.
struct ToolCallCard: View {
    let call: DaemonToolCall
    var durationMs: Int? = nil
    var isRunning = false
    @State private var expanded = false
    private var expansion: Binding<Bool>?
    @State private var selectedOutput: ToolOutputDocument?

    init(call: DaemonToolCall, durationMs: Int? = nil, initiallyExpanded: Bool = false, isRunning: Bool = false, expansion: Binding<Bool>? = nil) {
        self.call = call
        self.durationMs = durationMs
        self.isRunning = isRunning
        self.expansion = expansion
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: expansion ?? $expanded) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if let surface = call.action?.surface {
                    DesktopToolContent(action: surface)
                } else {
                    if let input = call.transcriptInputText, !input.isEmpty {
                        textBlock(input, label: t(call.isShellCommand ? "chat.tool.command" : "chat.tool.input"))
                    }
                    if let output = call.output, !output.isEmpty {
                        textBlock(output, label: t("chat.tool.output"), error: call.isError == true)
                    } else {
                        if let stdout = call.action?.shell?.stdout, !stdout.isEmpty {
                            textBlock(stdout, label: t("chat.tool.output"))
                        }
                        if let stderr = call.action?.shell?.stderr, !stderr.isEmpty {
                            textBlock(stderr, label: t("chat.tool.stderr"), error: call.isError == true)
                        }
                    }
                    if let code = call.action?.shell?.exitCode {
                        LabeledContent(t("chat.tool.exitCode"), value: String(code))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { (expansion ?? $expanded).wrappedValue = false } label: {
                    Label("Collapse", icon: .chevronUp).font(.caption.weight(.medium))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(minHeight: 32)
                .accessibilityIdentifier("chat.tool.collapse")
            }
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.sm)
        } label: {
            HStack(spacing: Spacing.sm) {
                ChatToolIcon(symbol: toolIcon)
                if call.isShellCommand {
                    Text(call.shellCommandText ?? call.action?.title ?? t("chat.tool.command"))
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(call.action?.surface != nil ? call.action?.title ?? "Desktop" : call.name ?? "Tool")
                        .lineLimit(1)
                    if call.action?.surface == nil, let summary {
                        Text(summary).font(.caption)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: Spacing.sm)
                if call.isError == true {
                    AppIcon(.warning, size: ChatContentStyle.iconSize).foregroundStyle(Palette.danger)
                        .accessibilityLabel(t("chat.tool.failed"))
                } else if isRunning {
                    ProgressView().controlSize(.mini).accessibilityLabel(t("chat.running"))
                } else if let ms = durationMs, ms >= 500 {
                    Text("\(max(1, ms / 1000))s").font(.caption).foregroundStyle(.secondary)
                        .monospacedDigit().fixedSize()
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .font(.subheadline)
        .tint(.secondary)
        .disclosureGroupStyle(ChatToolDisclosureStyle(identifier: "chat.tool.\(call.id)"))
        .sheet(item: $selectedOutput) { document in ToolOutputSheet(document: document) }
    }

    // MARK: - Content

    /// One-line collapsed summary from the most telling input key.
    private var summary: String? {
        if let title = call.action?.title, !title.isEmpty { return title }
        guard let i = call.input else { return nil }
        for key in ["command", "file_path", "path", "pattern", "url", "query"] {
            if let v = i[key]?.string, !v.isEmpty {
                return (key == "file_path" || key == "path") ? (v as NSString).lastPathComponent : v
            }
        }
        return nil
    }

    private func textBlock(_ s: String, label: String, error: Bool = false) -> some View {
        let preview = ToolOutputPreview(s)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(error ? Palette.danger : .secondary)
                Spacer()
                if preview.isTruncated {
                    Button("View full output") { selectedOutput = .init(title: label, text: s) }
                        .font(.caption.weight(.medium)).buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityIdentifier("chat.tool.fullOutput")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(preview.text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(Spacing.md)
            }
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: Radius.sm))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolIcon: AppIconName {
        if call.action?.surface != nil { return .monitor }
        if call.isShellCommand { return Icon.terminal }
        switch call.action?.kind {
        case "shell": return Icon.terminal
        case "file_read", "file_edit": return .fileText
        case "search": return .search
        case "web_search", "web_fetch": return .globe
        case "mcp": return .plug
        default:
            switch call.name {
            case "Bash", "shell", "exec_command": return Icon.terminal
            case "Read", "view_image": return .fileText
            case "Grep", "Glob": return .search
            case "WebFetch", "WebSearch", "web_search": return .globe
            case "Task", "spawnAgent", "wait": return .users
            default: return .wrench
            }
        }
    }
}

/// Keep transcript cells bounded. Full logs use native text scrolling in a sheet
/// whose Done control stays visible, regardless of the output length.
struct ToolOutputPreview {
    let text: String
    let isTruncated: Bool
    init(_ text: String) {
        let prefix = text.prefix(4_000)
        let lines = prefix.split(separator: "\n", maxSplits: 12, omittingEmptySubsequences: false)
        let visible = lines.prefix(12).joined(separator: "\n")
        isTruncated = visible.utf8.count < text.utf8.count
        self.text = visible + (isTruncated ? "\n…" : "")
    }
}

struct ChatToolDisclosureStyle: DisclosureGroupStyle {
    let identifier: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: Spacing.sm) {
                    configuration.label
                    AppIcon(configuration.isExpanded ? .chevronDown : .chevronRight, size: 10)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}

private struct ToolOutputDocument: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}
private struct ToolOutputSheet: View {
    let document: ToolOutputDocument
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CodeEditorView(text: .constant(document.text), language: nil, fontSize: 14,
                           isDark: colorScheme == .dark, wrapLines: false, isEditable: false)
                .accessibilityIdentifier("chat.tool.output")
                .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { dismiss() } }
                    AppToolbarItem(placement: .topBarLeading) {
                        Button { UIPasteboard.general.string = document.text } label: { Label(t("chat.copy"), icon: .copy) }
                    }
                }
        }
        .presentationDetents([.large])
    }
}
