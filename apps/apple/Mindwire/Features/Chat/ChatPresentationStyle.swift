import SwiftUI

/// Explicit activity tint survives neutral toolbar and disclosure styling.
/// Scope it to indicators so Cancel, Done and other native controls stay neutral.
private struct ChatActivityTint: ViewModifier {
    @Environment(\.chatAccent) private var accent

    func body(content: Content) -> some View { content.tint(accent) }
}

extension View {
    func chatActivityTint() -> some View { modifier(ChatActivityTint()) }
}

private struct DesktopMessengerKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var desktopMessenger: Bool {
        get { self[DesktopMessengerKey.self] }
        set { self[DesktopMessengerKey.self] = newValue }
    }
}

/// Keep identity outside Menu: Catalyst can collapse a composite menu label to plain text.
/// The header receives presentation state only; all actions still belong to the shared chat.
struct DesktopChatHeader<Actions: View>: View {
    @Environment(AppModel.self) private var app
    let bot: AssistantBot?
    let title: String
    let computerName: String?
    let status: String?
    let canOpenComputer: Bool
    let openHistory: () -> Void
    let openComputer: () -> Void
    @ViewBuilder let actions: () -> Actions
    private var leadingNavigationVisible: Bool { app.desktopNavigationVisible || app.desktopBotRailVisible }

    var body: some View {
        HStack(spacing: 12) {
            if !leadingNavigationVisible {
                DesktopNavigationToggle()
                if app.desktopProjectIsOpen {
                    Button { app.showProjects() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(AssistantDesktopButtonStyle()).help("Back to Projects")
                        .accessibilityLabel("Back to Projects").accessibilityIdentifier("desktop.project.back")
                }
            }
            if let bot {
                AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: 28)
            } else {
                AssistantBrandMark(size: 24).frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    .accessibilityIdentifier("chat-title")
                if computerName != nil || status != nil {
                    HStack(spacing: 5) {
                        if status != nil { ProgressView().controlSize(.mini).chatActivityTint() }
                        Text([computerName, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if canOpenComputer {
                    Button(action: openComputer) { actionIcon(.monitor) }
                        .help(computerName ?? t("assistant.computer"))
                        .accessibilityLabel(computerName ?? t("assistant.computer"))
                }
                AppMenu {
                    Button(action: openHistory) { Label(t("assistant.history"), icon: .history) }
                    Divider()
                    actions()
                } label: { actionIcon(.more) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(t("assistant.sidebar.options"))
                    .accessibilityLabel(t("assistant.sidebar.options"))
            }
            .buttonStyle(AssistantDesktopButtonStyle())
        }
        .tint(.primary)
        .padding(.horizontal, AssistantDesktopStyle.gutter)
        .padding(.leading, leadingNavigationVisible ? 0 : 76)
        .frame(maxWidth: .infinity)
        .frame(height: AssistantDesktopStyle.headerHeight)
        .background(AssistantDesktopStyle.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(AssistantDesktopStyle.separator).frame(height: 0.5) }
    }

    private func actionIcon(_ icon: AppIconName) -> some View {
        AppIcon(icon, size: 17).foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .contentShape(.rect(cornerRadius: 11, style: .continuous))
    }
}

/// Presentation-only styling; the same markdown, selection and native tool views render inside.
struct ChatAssistantBubble: ViewModifier {
    @Environment(\.desktopMessenger) private var desktop

    func body(content: Content) -> some View {
        if desktop {
            content
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(AssistantDesktopStyle.surface,
                            in: .rect(cornerRadius: AssistantDesktopStyle.messageRadius, style: .continuous))
                // Cap the layout after painting the content, so a short reply has a short bubble.
                .frame(maxWidth: 732, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 56)
        } else { content }
    }
}

enum ChatContentStyle {
    static let partSpacing = Spacing.sm - 1
    static let iconSize: CGFloat = 18
    static let iconWidth: CGFloat = 20
}

struct ChatToolIcon: View {
    let symbol: AppIconName
    var body: some View {
        AppIcon(symbol, size: ChatContentStyle.iconSize)
            .frame(width: ChatContentStyle.iconWidth, height: ChatContentStyle.iconWidth)
            .accessibilityHidden(true)
    }
}

/// Shared Mindwire identity while a small indeterminate ring shows real history work.
struct ChatHistoryLoadingView: View {
    var agentType: AgentID?

    var body: some View {
        ProgressView(t("chat.history.loading"))
            .progressViewStyle(ChatHistoryProgressStyle(agentType: agentType))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("chat-history-loading")
    }
}

/// Latest-message refreshes belong to the title; older paging stays in the scroller.
/// Brief metadata checks finish before the indicator appears.
struct ChatNavigationTitle: View {
    let title: String
    let subtitle: String
    let refreshing: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsProgress = false

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("chat-title")
                if showsProgress {
                    ProgressView().controlSize(.mini)
                        .chatActivityTint()
                        .frame(width: 12, height: 12)
                        .accessibilityLabel("Updating conversation")
                        .accessibilityIdentifier("chat-history-refreshing")
                }
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: sizeClass == .regular ? 420 : 245)
        .allowsHitTesting(false)
        .task(id: refreshing) {
            guard refreshing else { showsProgress = false; return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            showsProgress = true
        }
    }
}

private struct ChatHistoryProgressStyle: ProgressViewStyle {
    let agentType: AgentID?
    @Environment(\.chatAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: Spacing.md) {
            AgentActivityGlyph(agentType: nil, color: accent)
            configuration.label.font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Consecutive outgoing messages share tight corners; only the final bubble has a tail.
struct ChatUserBubble: View {
    let text: String
    var joinsAbove = false
    var joinsBelow = false
    var attachments: [DaemonAttachment] = []
    @Environment(\.chatBotColor) private var botColor
    @Environment(\.desktopMessenger) private var desktop

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Spacing.xl)
            VStack(alignment: .trailing, spacing: Spacing.sm) {
                if !attachments.isEmpty {
                    let photos = attachments.filter(\.isImage)
                    let files = attachments.filter { !$0.isImage }
                    if photos.count == 1, let photo = photos.first {
                        ChatImageThumbnail(attachment: photo, size: CGSize(width: 236, height: 178))
                    } else if !photos.isEmpty {
                        LazyVGrid(columns: [GridItem(.fixed(114)), GridItem(.fixed(114))], alignment: .trailing, spacing: Spacing.sm) {
                            ForEach(photos.indices, id: \.self) { index in
                                ChatImageThumbnail(attachment: photos[index], size: CGSize(width: 114, height: 114))
                            }
                        }
                        .frame(width: 236)
                    }
                    ForEach(files.indices, id: \.self) { index in
                        ChatImageThumbnail(attachment: files[index], size: CGSize(width: 236, height: 64))
                    }
                }
                if !text.isEmpty {
                    if desktop {
                        MessageContentView(text: text, onAccent: true).equatable()
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(AssistantDesktopStyle.outgoing,
                                        in: .rect(cornerRadius: AssistantDesktopStyle.messageRadius, style: .continuous))
                    } else {
                        MessageContentView(text: text, onAccent: true).equatable()
                            .padding(.horizontal, Spacing.md + 2)
                            .padding(.vertical, Spacing.sm + 2)
                            .padding(.trailing, 6)
                            .background((botColor ?? .brand).fill, in: OutgoingBubbleShape(joinsAbove: joinsAbove, joinsBelow: joinsBelow))
                    }
                }
            }
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
                desktop ? min(560, max(0, width - AssistantDesktopStyle.gutter * 2) * 0.72)
                    : (width - Spacing.lg * 2) * 0.78
            }
        }
    }
}

private struct OutgoingBubbleShape: Shape {
    var joinsAbove: Bool
    var joinsBelow: Bool

    func path(in rect: CGRect) -> Path {
        let right = rect.maxX - 6, bottom = rect.maxY
        let radius = min(20.0, rect.height / 2)
        let topRight = joinsAbove ? 6.0 : radius
        let bottomRight = joinsBelow ? 6.0 : radius
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: right - topRight, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + topRight), control: CGPoint(x: right, y: rect.minY))
        if joinsBelow {
            path.addLine(to: CGPoint(x: right, y: bottom - bottomRight))
            path.addQuadCurve(to: CGPoint(x: right - bottomRight, y: bottom), control: CGPoint(x: right, y: bottom))
        } else {
            path.addLine(to: CGPoint(x: right, y: bottom - radius))
            path.addCurve(to: CGPoint(x: rect.maxX, y: bottom),
                          control1: CGPoint(x: right, y: bottom - 8), control2: CGPoint(x: right + 2, y: bottom - 2))
            path.addCurve(to: CGPoint(x: right - 10, y: bottom - 4),
                          control1: CGPoint(x: right, y: bottom + 1), control2: CGPoint(x: right - 7, y: bottom - 1))
            path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right - 14, y: bottom))
        }
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - radius), control: CGPoint(x: rect.minX, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
