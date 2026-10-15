import SwiftUI

/// Renders an assistant turn's ORDERED parts (text / thinking / tool) in sequence — shared by the
/// live in-flight turn and the committed history row, so both look identical. Tool parts route to a
/// diff card (Edit/Write/MultiEdit) or the generic collapsible tool card.
///
/// Used by compact previews. The full transcript virtualizes these same part views individually.
struct TurnPartsView: View {
    let parts: [DaemonMessagePart]
    var isLive = false
    /// Only tools first observed live in this visit auto-expand. History and replay start closed.
    var autoExpandedToolIDs: Set<String> = []
    /// True for pending requests on the live run or actionable prompts in the latest history turn.
    var interactionsActive = false
    /// The chat presents its shared answer sheet; the transcript never embeds an editable form.
    var onOpenInteraction: ((DaemonInteraction) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: ChatContentStyle.partSpacing) {
            ForEach(ChatPartGroup.make(parts)) { group in
                Group {
                    if group.isCommandGroup {
                        CommandGroupView(parts: group.parts,
                                         isLive: isLive && group.startIndex + group.parts.count == parts.count)
                    } else if let part = group.parts.first {
                        TurnPartView(part: part, isLive: isLive, isLast: group.startIndex == parts.count - 1,
                                     autoExpanded: part.tool.map { autoExpandedToolIDs.contains($0.id) } ?? false,
                                     interactionsActive: interactionsActive, onOpenInteraction: onOpenInteraction)
                            .equatable()
                    }
                }
                .padding(.top, group.startsBlock ? Spacing.md : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Immutable completed steps do not reparse markdown/diffs when another step receives a token.
struct TurnPartView: View, Equatable {
    let part: DaemonMessagePart
    var isLive = false
    var isLast = false
    var autoExpanded = false
    var interactionsActive = false
    var onOpenInteraction: ((DaemonInteraction) -> Void)? = nil
    var toolExpansion: Binding<Bool>? = nil
    @Environment(\.horizontalSizeClass) private var hSizeClass

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.part == rhs.part && lhs.isLive == rhs.isLive && lhs.isLast == rhs.isLast
            && lhs.autoExpanded == rhs.autoExpanded && lhs.interactionsActive == rhs.interactionsActive
            && (lhs.onOpenInteraction == nil) == (rhs.onOpenInteraction == nil)
            && lhs.toolExpansion?.wrappedValue == rhs.toolExpansion?.wrappedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatContentStyle.partSpacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch part.kind {
        case .user:
            if let input = part.input { ChatUserBubble(text: input.text, attachments: input.attachments ?? []) }
        case .text:
            MessageContentView(text: part.text ?? "")
                .frame(maxWidth: hSizeClass == .regular ? 640 : .infinity, alignment: .leading)
        case .thinking:
            ThinkingBlock(text: part.text ?? "", durationMs: part.durationMs, tokens: part.tokens,
                          isLive: isLive && part.durationMs == nil && isLast)
        case .tool:
            if let call = part.tool {
                if !call.fileEdits.isEmpty {
                    ForEach(call.fileEdits, id: \.path) { edit in
                        ToolDiffCard(edit: edit, isError: call.isError == true,
                                     initiallyExpanded: autoExpanded)
                    }
                    if call.isError == true, let output = call.output, !output.isEmpty {
                        ChatErrorDisclosure(title: t("chat.tool.failed"), detail: output)
                    }
                } else {
                    ToolCallCard(call: call, durationMs: part.durationMs,
                                 isRunning: isLive && isLast && part.hasPendingToolResult, expansion: toolExpansion)
                }
            }
        case .interaction:
            if let it = part.interaction {
                if it.isAnswerPrompt {
                    InteractionSummaryView(interaction: it,
                        onOpen: onOpenInteraction != nil && it.needsResponse == true
                            && (interactionsActive || (it.isMessageQuestion && it.runId != nil))
                            ? { onOpenInteraction?(it) } : nil)
                } else {
                    InteractionView(interaction: it)
                }
            }
        case .compaction:
            DisclosureGroup {
                if let summary = part.compaction?.summary, !summary.isEmpty { MessageContentView(text: summary) }
            } label: {
                Label(t("chat.compacted"), icon: .refresh)
                    .font(.callout).foregroundStyle(.secondary)
            }
            .tint(.primary)
        }
    }
}
