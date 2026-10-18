import SwiftUI

/// The General drawer's chrome. History and conversation actions remain in ChatHistorySheet.
struct AssistantHistorySidebar<Content: View>: View {
    @Binding var search: String
    let close: () -> Void
    var newChat: (() -> Void)?
    var settings: (() -> Void)?
    var account: (() -> Void)?
    var newBot: (() -> Void)?
    var archivedBots: (() -> Void)?
    var groupedByBots = false
    var developerSection: Binding<AppTab>?
    var newProject: (() -> Void)?
    var newComputer: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @FocusState private var searching: Bool
    @State private var auth = OblienAuth.shared
    @Environment(\.desktopSidebarCompact) private var compact

    var body: some View {
        if ApplePlatform.isDesktop { desktopSidebar }
        else { mobileSidebar }
    }

    private var mobileSidebar: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Section {
                content()
            } header: {
                Text(t(groupedByBots ? "assistant.bots.title" : "assistant.sidebar.chats"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .accessibilityIdentifier("assistant.sidebar.chats")
            }
        }
        .listStyle(.plain)
        .listRowSpacing(0)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 46)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("chat.history.list")
        .buttonStyle(.plain).tint(.primary).foregroundStyle(.primary)
        .background(AssistantStyle.canvas)
        .accessibilityAction(.escape, close)
    }

    private var desktopSidebar: some View {
        VStack(spacing: 0) {
            desktopHeader
            if !compact {
                if let developerSection {
                    Picker("Developer section", selection: developerSection) {
                        Text(t("tabs.agents")).tag(AppTab.agents)
                        Text(t("tabs.projects")).tag(AppTab.projects)
                        Text("Computers").tag(AppTab.workspaces)
                    }
                    .pickerStyle(.segmented).controlSize(.small)
                    .padding(.horizontal, AssistantDesktopStyle.sidebarInset).padding(.bottom, 12)
                    .accessibilityIdentifier("desktop.developer.section")
                }
                HStack(spacing: 10) {
                    AppIcon(.search, size: 18).foregroundStyle(.secondary)
                    TextField(desktopSearchTitle, text: $search)
                        .textFieldStyle(.plain).focused($searching)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("assistant.sidebar.search")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel(t("assistant.sidebar.clearSearch"))
                    }
                }
                .font(.system(size: 14)).padding(.horizontal, 12).frame(height: 42)
                .background(AssistantDesktopStyle.selection, in: .rect(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, AssistantDesktopStyle.sidebarInset).padding(.bottom, 10)
            }

            List { content() }
                .listStyle(.plain).listRowSpacing(compact ? 6 : 4)
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, 12, for: .scrollContent)
                .environment(\.defaultMinListRowHeight, compact ? 44 : 46)
                .scrollIndicators(compact ? .hidden : .automatic)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("chat.history.list")

            let footerLayout = compact ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 10))
            footerLayout {
                if let account {
                    Button(action: account) {
                        HStack(spacing: 10) {
                            Text(accountInitials).font(.caption.weight(.medium))
                                .foregroundStyle(.secondary).frame(width: 34, height: 34)
                                .background(AssistantDesktopStyle.selection, in: .circle)
                            if !compact {
                                Text(auth.user?.name ?? t("account.title"))
                                    .font(.subheadline).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.horizontal, compact ? 0 : 8).padding(.vertical, 7)
                    }
                    .buttonStyle(AssistantDesktopButtonStyle())
                    .help(auth.user?.name ?? t("account.title"))
                    .accessibilityLabel(auth.user?.name ?? t("account.title"))
                    .accessibilityIdentifier("assistant.sidebar.account")
                }
                DesktopConnectPhoneButton()
                    .labelStyle(.iconOnly).font(.system(size: 16)).frame(width: 34, height: 34)
                    .buttonStyle(AssistantDesktopButtonStyle())
                if let archivedBots {
                    Button(action: archivedBots) {
                        Image(systemName: "archivebox").font(.system(size: 16)).frame(width: 34, height: 34)
                    }
                    .buttonStyle(AssistantDesktopButtonStyle())
                    .help(t("assistant.bots.archived"))
                    .accessibilityLabel(t("assistant.bots.archived"))
                }
                if let settings {
                    Button(action: settings) { AppIcon(.settings, size: 18).frame(width: 34, height: 34) }
                        .buttonStyle(AssistantDesktopButtonStyle())
                        .help(t("tabs.settings"))
                        .accessibilityLabel(t("tabs.settings"))
                        .accessibilityIdentifier("assistant.sidebar.settings")
                }
            }
            .foregroundStyle(.secondary)
            .frame(height: compact ? nil : 54)
            .padding(.horizontal, compact ? 14 : AssistantDesktopStyle.sidebarInset)
            .padding(.top, Spacing.sm).padding(.bottom, 16)
        }
        .buttonStyle(.plain).tint(.primary).foregroundStyle(.primary)
        .background(AssistantDesktopStyle.sidebar)
        .onChange(of: compact) { if compact { searching = false } }
    }

    @ViewBuilder private var desktopHeader: some View {
        if compact {
            VStack(spacing: 4) {
                DesktopNavigationToggle()
                desktopCreateButton
            }
            .padding(.top, 32).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        } else {
            HStack {
                Spacer()
                DesktopNavigationToggle()
                desktopCreateButton
            }
            .frame(height: AssistantDesktopStyle.headerHeight)
            .padding(.horizontal, AssistantDesktopStyle.sidebarInset)
        }
    }

    @ViewBuilder private var desktopCreateButton: some View {
        if let action = desktopCreateAction {
            Button(action: action) {
                AppIcon(.plus, size: 19).foregroundStyle(.secondary).frame(width: 34, height: 34)
            }
            .buttonStyle(AssistantDesktopButtonStyle())
            .help(desktopCreateTitle).accessibilityLabel(desktopCreateTitle)
            .accessibilityIdentifier("assistant.bots.create")
        }
    }

    private var desktopCreateAction: (() -> Void)? {
        switch developerSection?.wrappedValue {
        case .projects: newProject
        case .workspaces: newComputer
        default: newBot ?? newChat
        }
    }

    private var desktopCreateTitle: String {
        switch developerSection?.wrappedValue {
        case .projects: "New project"
        case .workspaces: "Add computer"
        default: t(groupedByBots ? "assistant.bots.create" : "assistant.newChat")
        }
    }

    private var desktopSearchTitle: String {
        switch developerSection?.wrappedValue {
        case .projects: "Search projects"
        case .workspaces: "Search computers"
        case .agents: "Search agents"
        default: t("assistant.sidebar.search")
        }
    }

    private var accountInitials: String {
        guard let name = auth.user?.name, !name.isEmpty else { return "M" }
        return name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// A regular first row, so the logo, search and actions scroll with the conversations.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AssistantBrandMark(size: 28)
                    .frame(width: 32, height: 40)
                Text("Mindwire").font(.title3.weight(.light)).tracking(-0.3).lineLimit(1)
                Spacer(minLength: 0)
                if settings != nil || account != nil || newBot != nil {
                    Menu {
                        if let newBot {
                            Button(action: newBot) { Label(t("assistant.bots.create"), systemImage: "plus") }
                                .accessibilityIdentifier("assistant.bots.create")
                        }
                        if let archivedBots {
                            Button(action: archivedBots) { Label(t("assistant.bots.archived"), systemImage: "archivebox") }
                        }
                        if newBot != nil || archivedBots != nil { Divider() }
                        if let settings {
                            Button(action: settings) {
                                Label(t("tabs.settings"), systemImage: "gearshape")
                            }
                            .accessibilityIdentifier("assistant.sidebar.settings")
                        }
                        if let account {
                            Button(action: account) {
                                Label(t("account.title"), systemImage: "person.crop.circle")
                            }
                            .accessibilityIdentifier("assistant.sidebar.account")
                        }
                    } label: {
                        headerIcon("ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel(t("assistant.sidebar.options"))
                    .accessibilityIdentifier("assistant.sidebar.options")
                    .fixedSize()
                }
            }
            .padding(.leading, 20).padding(.trailing, 10).padding(.top, 8)
            .padding(.bottom, 20)

            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(.secondary)
                    TextField(t("assistant.sidebar.search"), text: $search)
                        .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).focused($searching)
                        .accessibilityIdentifier("assistant.sidebar.search")
                    if !search.isEmpty {
                        Button { search = ""; searching = false } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.subheadline).foregroundStyle(.tertiary).frame(width: 32, height: 44)
                        }
                        .accessibilityLabel(t("assistant.sidebar.clearSearch"))
                        .accessibilityIdentifier("assistant.sidebar.clearSearch")
                    }
                }
                .padding(.leading, 12).padding(.trailing, search.isEmpty ? 12 : 2)
                .frame(minHeight: 44)
                .background(AssistantStyle.surface, in: .capsule)

                if let create = groupedByBots ? newBot : newChat {
                    Button(action: create) {
                        Image(systemName: "plus")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.black)
                            .frame(width: 40, height: 40)
                            .background(.white, in: .circle)
                            .overlay { Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel(t(groupedByBots ? "assistant.bots.create" : "assistant.newChat"))
                    .accessibilityIdentifier("assistant.sidebar.newChat")
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16)

        }
        .padding(.bottom, 12)
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body.weight(.medium))
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

/// Plain conversation titles, with a quiet highlight for the currently open chat.
struct AssistantConversationLabel: View {
    let title: String
    var selected = false
    var status: RunStatus?
    var busy = false
    var muted = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.body).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if busy || status == .running {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel(t(busy ? "chat.history.loading" : "chat.running"))
            } else if status == .error {
                AppIcon(.warning, size: 16).foregroundStyle(.secondary)
                    .accessibilityLabel(t("chat.error.title"))
            }
            if muted {
                AppIcon(.bellOff, size: 16).foregroundStyle(.secondary)
                    .accessibilityLabel(t("notifications.muted"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 12)
        .frame(minHeight: 46)
        .background(selected ? AssistantStyle.surface : .clear, in: .rect(cornerRadius: 18))
        .contentShape(.rect(cornerRadius: 18))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A bot is the destination; its latest conversation supplies live status and a real preview.
/// Reading the bounded session cache never starts history work or persists transcript copies.
struct AssistantBotConversationRow: View {
    let bot: AssistantBot
    let chat: Chat?
    var selected = false
    @Environment(\.stores) private var stores
    @State private var activity = ChatActivityStore.shared
    @State private var hovered = false
    @Environment(\.desktopSidebarCompact) private var compact

    var body: some View {
        Group {
            if compact {
                avatar.frame(width: 44, height: 44)
                    .background(rowBackground, in: .rect(cornerRadius: 13))
                    .contentShape(.rect(cornerRadius: 13))
                    .help(bot.name).accessibilityLabel(bot.name)
            } else { expandedRow }
        }
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var avatar: some View {
        AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: compact ? 30 : ApplePlatform.isDesktop ? 34 : 40)
            .overlay(alignment: .topTrailing) {
                if let chat {
                    if activity.status(chat.id) == .error {
                        Circle().fill(.red).frame(width: 9, height: 9)
                            .accessibilityLabel(t("chat.error.title"))
                    } else if compact, activity.status(chat.id) == .running {
                        Circle().fill(Palette.accent).frame(width: 7, height: 7)
                    }
                }
            }
    }

    private var expandedRow: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: ApplePlatform.isDesktop ? 4 : 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bot.name).font(ApplePlatform.isDesktop ? .system(size: 15) : .body).lineLimit(1)
                        .accessibilityIdentifier("assistant.bot.name.\(bot.id)")
                    Spacer(minLength: 0)
                    if let chat, let date = activity.lastActivity(chat) {
                        RelativeTimestamp(date: date).font(ApplePlatform.isDesktop ? .system(size: 11) : .caption2)
                    }
                }
                HStack(spacing: 6) {
                    if let chat, activity.status(chat.id) == .running { ProgressView().controlSize(.mini) }
                    Text(preview).font(ApplePlatform.isDesktop ? .system(size: 13) : .subheadline)
                        .foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, ApplePlatform.isDesktop ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: .rect(cornerRadius: ApplePlatform.isDesktop ? AssistantDesktopStyle.rowRadius : 14, style: .continuous))
        .contentShape(.rect(cornerRadius: ApplePlatform.isDesktop ? AssistantDesktopStyle.rowRadius : 14, style: .continuous))
    }

    private var rowBackground: Color {
        if selected { return ApplePlatform.isDesktop ? AssistantDesktopStyle.selection : AssistantStyle.surface }
        return ApplePlatform.isDesktop && hovered ? AssistantDesktopStyle.selection.opacity(0.55) : .clear
    }

    private var preview: String {
        if let chat {
            if let text = stores.chatSessions.cached(chat.id)?.messages.last(where: { !$0.text.isEmpty })?.text {
                return String(text.prefix(180)).replacingOccurrences(of: "\n", with: " ")
            }
            return activity.title(chat)
        }
        return bot.purpose.isEmpty ? t("assistant.bots.noChats") : bot.purpose
    }
}
