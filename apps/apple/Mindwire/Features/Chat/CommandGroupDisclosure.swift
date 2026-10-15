import SwiftUI

/// Shared native disclosure for grouped commands. The transcript supplies its children as
/// separate table rows; compact previews put the same tool disclosures inside the group.
struct CommandGroupDisclosure<Content: View>: View {
    let parts: [DaemonMessagePart]
    var isLive = false
    @Binding var expanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $expanded, content: content) {
            HStack(spacing: Spacing.sm) {
                ChatToolIcon(symbol: Icon.terminal)
                Text(t("chat.commands.count", ["n": "\(parts.count)"]))
                    .fontWeight(.medium).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if parts.contains(where: { $0.tool?.isError == true }) {
                    AppIcon(.warning, size: ChatContentStyle.iconSize)
                        .foregroundStyle(Palette.danger)
                        .accessibilityLabel(t("chat.tool.failed"))
                }
                if isLive && parts.contains(where: \.hasPendingToolResult) {
                    ProgressView().controlSize(.mini).accessibilityLabel(t("chat.running"))
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .font(.subheadline)
        .tint(.secondary)
        .disclosureGroupStyle(ChatToolDisclosureStyle(identifier: "chat.commandGroup"))
    }
}

struct CommandGroupView: View {
    let parts: [DaemonMessagePart]
    var isLive = false
    @State private var expanded = false

    var body: some View {
        CommandGroupDisclosure(parts: parts, isLive: isLive, expanded: $expanded) {
            VStack(alignment: .leading, spacing: ChatContentStyle.partSpacing) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if let call = part.tool {
                        ToolCallCard(call: call, durationMs: part.durationMs,
                                     isRunning: isLive && part.hasPendingToolResult)
                    }
                }
            }
            .padding(.leading, Spacing.md)
        }
    }
}
