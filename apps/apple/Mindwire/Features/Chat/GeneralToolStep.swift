import SwiftUI

/// Presentation only: no extra model requests and no changes to the saved transcript.
struct GeneralToolStep: View {
    let call: DaemonToolCall
    var isRunning = false
    @Environment(\.chatAccent) private var accent

    var body: some View {
        HStack(spacing: 7) {
            if isRunning && call.isError != true {
                ProgressView().chatActivityTint().controlSize(.mini).frame(width: 13, height: 13)
            } else {
                Image(systemName: call.isError == true ? "exclamationmark.circle" : presentation.icon)
                    .font(.system(size: 12, weight: .medium))
            }
            Text(presentation.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if call.isError == true { Text("· Needs attention").font(.system(size: 11)) }
        }
        .foregroundStyle(call.isError == true ? Palette.danger : isRunning ? accent : .secondary)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background((isRunning ? accent.opacity(0.08) : Color(uiColor: .tertiarySystemFill)), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isRunning ? "In progress" : call.isError == true ? "Couldn’t finish" : "Completed")
    }

    private var presentation: (title: String, icon: String) {
        let name = (call.action?.mcp?.tool ?? call.name ?? "").lowercased()
        switch call.action?.kind {
        case "file_read": return ("Read files", "doc.text")
        case "file_edit": return ("Update files", "doc.badge.gearshape")
        case "search": return ("Find information", "magnifyingglass")
        case "web_search", "web_fetch": return ("Search the web", "globe")
        default: break
        }
        if call.action?.surface != nil { return ("Use computer", "cursorarrow") }
        if name.contains("apps_request_publish") { return ("Prepare publishing", "globe") }
        if name.contains("apps_register") || name.contains("apps_update") { return ("Save app", "square.grid.2x2") }
        if name.contains("schedule") { return ("Manage schedule", "calendar") }
        if name.contains("notification") { return ("Set up notifications", "bell") }
        if name.contains("bots_") { return ("Manage bots", "person.2") }
        if name.contains("skill") || name.contains("knowledge") || name.contains("memory") { return ("Read guidance", "book") }
        if ["read", "view_image", "read_file"].contains(name) { return ("Read files", "doc.text") }
        if ["edit", "write", "multiedit", "apply_patch"].contains(name) { return ("Update files", "doc.badge.gearshape") }
        if name.contains("search") || name.contains("fetch") { return ("Search the web", "globe") }
        if ["grep", "glob", "list_directory"].contains(name) { return ("Find files", "magnifyingglass") }
        if call.isShellCommand {
            let command = (call.shellCommandText ?? "").lowercased()
            if command.contains("--bot-tool") { return ("Manage app", "square.grid.2x2") }
            if command.range(of: #"\b(install|add)\b"#, options: .regularExpression) != nil { return ("Set up app", "shippingbox") }
            if command.range(of: #"\b(build|compile)\b"#, options: .regularExpression) != nil { return ("Build app", "hammer") }
            if command.range(of: #"\b(test|check|lint)\b"#, options: .regularExpression) != nil { return ("Check work", "checkmark.shield") }
            if command.range(of: #"\b(curl|wget)\b"#, options: .regularExpression) != nil { return ("Check connection", "network") }
            if command.range(of: #"\b(ls|cat|rg|find|head|sed)\b"#, options: .regularExpression) != nil { return ("Explore files", "folder") }
            if command.range(of: #"\b(start|serve|dev)\b"#, options: .regularExpression) != nil { return ("Start app", "play") }
            return ("Work on task", "gearshape")
        }
        return ("Complete a step", "checkmark.circle")
    }
}

struct GeneralToolSteps: View {
    let parts: [DaemonMessagePart]
    var isLive = false

    // Action cards remain full-width and actionable, even when the harness used
    // a command helper for its native tools. Only ordinary steps share a row.
    private struct Group { var parts: [DaemonMessagePart]; let isCard: Bool }
    private var groups: [Group] {
        var result: [Group] = []
        for part in parts {
            let card = part.tool?.mindwireCard != nil
            if !card, result.last?.isCard == false {
                result[result.count - 1].parts.append(part)
            } else { result.append(.init(parts: [part], isCard: card)) }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                if group.isCard, let part = group.parts.first, let call = part.tool {
                    ToolCallCard(call: call, isRunning: isLive && part.hasPendingToolResult)
                } else {
                    ToolStepWrapLayout {
                        ForEach(Array(group.parts.enumerated()), id: \.offset) { _, part in
                            if let call = part.tool {
                                GeneralToolStep(call: call, isRunning: isLive && part.hasPendingToolResult)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ToolStepWrapLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 600, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (index, item) in layout.items.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                                  proposal: ProposedViewSize(item.size))
        }
    }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, items: [CGRect]) {
        let width = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var items: [CGRect] = []
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(.init(width: width, height: nil)) }
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + 7; rowHeight = 0 }
            items.append(CGRect(origin: .init(x: x, y: y), size: size))
            x += size.width + 7; rowHeight = max(rowHeight, size.height)
        }
        return (.init(width: width, height: y + rowHeight), items)
    }
}
