import SwiftUI

/// The same navigation, native preview and confirmed actions in every chat list.
struct ChatListRow: View {
    let chat: Chat
    var subtitle: String? = nil
    var onOpen: (() -> Void)? = nil
    var onChanged: () -> Void = {}

    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @State private var activity = ChatActivityStore.shared
    @State private var actions = ChatListActions.shared
    @State private var confirmingDelete = false
    @State private var renaming = false
    @State private var showingNotifications = false
    @State private var renameText = ""
    @State private var error: String?

    private var title: String { activity.title(stores.chats.get(chat.id) ?? chat) }
    private var busy: Bool { actions.pending.contains(chat.id) }

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { label }.tint(.primary)
            } else {
                NavigationLink(value: AppRoute.chat(chatId: chat.id)) { label }
            }
        }
        .appContextMenu {
            Button(action: open) { Label(t("chat.open"), icon: Icon.chat) }
            Button {
                renameText = title
                renaming = true
            } label: { Label(t("common.rename"), icon: Icon.edit) }
            .disabled(busy)
            Button { showingNotifications = true } label: {
                Label(t("notifications.title"), icon: .bell)
            }
            DestructiveButton(t("common.delete"), icon: Icon.trash) { confirmingDelete = true }
            .disabled(busy)
        } preview: {
            ChatPreview(chat: chat, title: title)
                .environment(\.stores, stores)
        }
        .sheet(isPresented: $showingNotifications) {
            ChatNotificationSettingsSheet(chatID: chat.id)
        }
        .alert(t("chat.rename.title"), isPresented: $renaming) {
            TextField(t("chat.rename.label"), text: $renameText)
            Button(t("common.save")) { perform { try await actions.rename(chat, title: renameText, stores: stores) } }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(t("common.cancel"), role: .cancel) {}
        }
        .alert(t("chat.delete.title"), isPresented: $confirmingDelete) {
            Button(t("common.delete"), role: .destructive) {
                perform { try await actions.delete(chat, stores: stores) }
            }
            Button(t("common.cancel"), role: .cancel) {}
        } message: { Text(t("chat.delete.runningBody", ["title": title])) }
        .alert(t("chat.actionFailed"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t("common.done"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var label: some View {
        HStack {
            ChatRowLabel(title: title, subtitle: subtitle, agentType: stores.agents.get(chat.agentId)?.agentType,
                         status: activity.status(chat.id),
                         date: activity.lastActivity(stores.chats.get(chat.id) ?? chat),
                         runStartedAt: activity.runStartedAt(chat.id),
                         loading: stores.chatSessions.cached(chat.id)?.isLoadingConversation == true)
            if NotificationScope.chat(chat.id).isMuted(in: stores) {
                AppIcon(.bellOff).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(t("notifications.muted"))
            }
            if busy { ProgressView().controlSize(.mini) }
        }
    }

    private func open() {
        if let onOpen { onOpen(); return }
        app.push(.chat(chatId: chat.id))
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action(); onChanged() }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// One chat row, shared by every chat-list surface (agent detail, project detail, history sheet).
/// `subtitle` carries the cross-scope label — the project name in an agent's list, the agent name
/// in a project's list. The logo uses the owning agent's bundled harness artwork, and status
/// comes from the shared daemon activity snapshot.
struct ChatRowLabel: View {
    let title: String
    var subtitle: String? = nil
    var agentType: AgentID? = nil
    var status: RunStatus? = nil
    var date: Date? = nil
    var runStartedAt: Date? = nil
    var loading = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            if let agentType {
                AgentLogo(id: agentType, size: 24).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.sm)
            VStack(alignment: .trailing, spacing: 3) {
                if status == .running {
                    ChatRunStatusLabel(status: status, startedAt: runStartedAt)
                } else {
                    if let date { RelativeTimestamp(date: date) }
                    if loading {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel(t("chat.history.loading"))
                            .accessibilityIdentifier("chat-row-loading")
                    } else {
                        ChatRunStatusLabel(status: status)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct ChatRunStatusLabel: View {
    let status: RunStatus?
    var startedAt: Date? = nil
    var body: some View {
        switch status {
        case .running:
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.mini).accessibilityLabel(t("chat.running"))
                if let startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(RelativeTime.elapsed(startedAt, now: context.date))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            .accessibilityElement(children: .combine)
        case .error:
            AppIcon(.warning)
                .font(.caption).foregroundStyle(Palette.danger)
                .accessibilityLabel(t("chat.error.title"))
        case .cancelled:
            Text(t("chat.stopped")).font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}
