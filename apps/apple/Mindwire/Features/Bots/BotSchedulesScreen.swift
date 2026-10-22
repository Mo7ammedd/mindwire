import SwiftUI

/// Browses one conversation at a time; opening this screen never fetches every chat's jobs.
struct BotSchedulesScreen: View {
    let bot: AssistantBot
    var embedded = false
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var chats: [Chat] = []
    @State private var selectedChatID: String?
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .onAppear(perform: reload)
        .onChange(of: stores.chats.revision) { reload() }
        .frame(minWidth: ApplePlatform.isDesktop ? 520 : nil, minHeight: ApplePlatform.isDesktop ? 480 : nil)
        .alert("Couldn't start a chat", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let chatID = selectedChatID {
                Menu {
                    Picker("Chat", selection: Binding(get: { chatID }, set: { selectedChatID = $0 })) {
                        ForEach(chats) { chat in
                            Text(chat.title.isEmpty ? "New chat" : chat.title).tag(chat.id)
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left").foregroundStyle(.secondary)
                        Text(chats.first(where: { $0.id == chatID })?.title ?? "New chat")
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain).tint(.primary)
                .accessibilityLabel("Choose chat").accessibilityIdentifier("bot.schedules.chat")
                .padding(.horizontal, 20).padding(.vertical, 12)
                Divider()
                ChatSchedulesContent(chatID: chatID).id(chatID)
            } else {
                ContentUnavailableView {
                    Label("Start with a chat", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Schedules send a prompt to a chat and keep the results there.")
                } actions: {
                    Button(creating ? "Starting…" : "Start a chat") { createChat() }
                        .buttonStyle(.glass).tint(.primary).disabled(creating)
                }
            }
        }
        .navigationTitle("Schedules").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !embedded {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(.primary)
                }
            }
        }
    }

    private func reload() {
        chats = stores.chatsByRecency().filter { $0.botId == bot.id }
        if !chats.contains(where: { $0.id == selectedChatID }) { selectedChatID = chats.first?.id }
    }

    private func createChat() {
        guard !creating else { return }
        creating = true
        Task { @MainActor in
            defer { creating = false }
            do { selectedChatID = try await BotConversationActions.createChat(for: bot, stores: stores).id }
            catch { if !error.isRequestCancellation { self.error = error.localizedDescription } }
        }
    }
}
