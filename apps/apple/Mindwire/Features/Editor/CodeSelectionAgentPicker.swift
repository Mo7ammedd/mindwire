import SwiftUI

/// Shared by Files and Source Control. Keep a snapshot so presenting the picker cannot lose the
/// selection when the native editor resigns focus.
struct SendToAgentPayload: Identifiable {
    let id = UUID()
    let path: String
    let code: String
    var context: String? = nil
    var format = ""

    var draft: String {
        // Selected Markdown can contain its own code fences.
        var fenceLength = 3
        var run = 0
        for character in code {
            run = character == "`" ? run + 1 : 0
            fenceLength = max(fenceLength, run + 1)
        }
        let fence = String(repeating: "`", count: fenceLength)
        let heading = [path, context].compactMap { $0 }.joined(separator: "\n")
        return "\(heading)\n\(fence)\(format)\n\(code)\n\(fence)\n\n"
    }
}

struct SendCodeToAgentButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(t("editor.sendToAgent"), icon: .send)
                .frame(maxWidth: .infinity).foregroundStyle(Palette.onAccent)
        }
        .buttonStyle(.glassProminent).controlSize(.regular)
        .accessibilityIdentifier("editor.sendToAgent")
    }
}

// File and diff selections use the shared new-chat model.
typealias CodeSelectionAgentModel = NewChatModel

private struct CodeSelectionAgentPresenter: ViewModifier {
    @Binding var payload: SendToAgentPayload?
    let projectId: String?
    let onOpenChat: ((String, String) -> Void)?
    @State private var pendingChat: ChatDraftRoute?

    func body(content: Content) -> some View {
        content.sheet(item: $payload, onDismiss: {
            guard let chat = pendingChat else { return }
            pendingChat = nil
            // Navigation starts after the picker finishes dismissing.
            onOpenChat?(chat.chatId, chat.draft)
        }) { selection in
            if let projectId {
                CodeSelectionAgentPicker(projectId: projectId, selection: selection) { chat in
                    pendingChat = chat
                    payload = nil
                }
            }
        }
    }
}

extension View {
    func sendCodeToAgent(_ payload: Binding<SendToAgentPayload?>, projectId: String?,
                         onOpenChat: ((String, String) -> Void)?) -> some View {
        modifier(CodeSelectionAgentPresenter(payload: payload, projectId: projectId, onOpenChat: onOpenChat))
    }
}

/// Files, diffs and New chat share the same bot/plain-agent choice and creation flow.
struct CodeSelectionAgentPicker: View {
    let projectId: String
    let selection: SendToAgentPayload
    let onReady: (ChatDraftRoute) -> Void

    var body: some View {
        ChatAgentPicker(projectId: projectId, title: t("editor.sendToAgent.pick"),
                        chatTitle: (selection.path as NSString).lastPathComponent) { chat in
            onReady(.init(chatId: chat.id, draft: selection.draft))
        }
    }
}
