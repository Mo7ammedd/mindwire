import SwiftUI

/// A bounded, read-only snapshot. No ChatModel, stream subscription, setup or transcript replay.
struct ChatPreview: View {
    let chat: Chat
    let title: String
    @Environment(\.stores) private var stores
    @State private var messages: [DaemonMessage] = []
    @State private var loading = true
    @State private var unavailable = false

    var body: some View {
        ChatPreviewContent(title: title, agent: stores.agents.get(chat.agentId), messages: messages,
                           loading: loading, unavailable: unavailable)
            .environment(\.chatProjectPath, stores.projects.get(chat.projectId)?.path)
            .task(id: chat.id) {
                if let cached = stores.chatSessions.cached(chat.id) {
                    // Join the same initial read if the conversation is already opening.
                    if cached.isInitiallyLoading { await cached.load() }
                    if cached.hasLoadedHistory {
                        messages = Array(cached.messages.suffix(6))
                        if let live = cached.live, !live.parts.isEmpty {
                            messages.append(.init(id: "preview-live", chatId: chat.id, role: .assistant,
                                text: live.text, createdAt: isoNow(), parts: live.parts))
                        }
                        loading = false
                        return
                    }
                }
                do {
                    let session = DaemonManager.shared.session(for: chat.agentId, stores: stores)
                    messages = try await session.readChatPreview(chat.id)
                    unavailable = false
                } catch {
                    if Task.isCancelled { return }
                    unavailable = true
                }
                loading = false
            }
    }
}

struct ChatPreviewContent: View {
    let title: String
    let agent: Agent?
    let messages: [DaemonMessage]
    var loading = false
    var unavailable = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                AppLogo(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text("Mindwire").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.md)
            .background(Color(uiColor: .systemBackground))
            .zIndex(1)
            Divider()
            if loading {
                ChatHistoryLoadingView(agentType: agent?.agentType)
            } else if messages.isEmpty {
                ContentUnavailableView {
                    Label(t(unavailable ? "chat.preview.unavailable" : "chat.preview.empty"), icon: Icon.chat)
                } description: {
                    if unavailable { Text(t("chat.preview.reconnect")) }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        ForEach(messages) { message in
                            if message.role == .user {
                                Text(message.text)
                                    .padding(Spacing.sm)
                                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            } else if let parts = message.parts, !parts.isEmpty {
                                TurnPartsView(parts: parts)
                            } else {
                                MessageContentView(text: message.text)
                                    .foregroundStyle(message.role == .system ? .secondary : .primary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.md)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
                .clipped()
                .allowsHitTesting(false)
            }
        }
        .frame(width: 330, height: 420)
        .background(Color(uiColor: .systemBackground))
        .ignoresSafeArea()
        .transaction { $0.animation = nil }
    }
}
