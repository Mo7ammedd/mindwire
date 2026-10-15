import SwiftUI

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

/// The harness stays recognizable while a small indeterminate ring shows real history work.
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

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: Spacing.md) {
            AgentActivityGlyph(agentType: agentType)
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
                    MessageContentView(text: text, onAccent: !ApplePlatform.isDesktop).equatable()
                        .padding(.horizontal, Spacing.md + 2)
                        .padding(.vertical, Spacing.sm + 2)
                        .padding(.trailing, 6)
                        .background(ApplePlatform.isDesktop ? Color.primary.opacity(0.07) : Palette.accent,
                                    in: OutgoingBubbleShape(joinsAbove: joinsAbove, joinsBelow: joinsBelow))
                }
            }
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
                (width - Spacing.lg * 2) * 0.78
            }
        }
    }
}

private struct OutgoingBubbleShape: Shape {
    var joinsAbove: Bool
    var joinsBelow: Bool

    func path(in rect: CGRect) -> Path {
        if ApplePlatform.isDesktop {
            return RoundedRectangle(cornerRadius: 22, style: .continuous).path(in: rect)
        }
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
