import SwiftUI

enum EntityRowStyle { case compact, card }

/// Shared list layout for agents, workspaces, and projects. The fixed icon column is
/// vertically centered beside the complete title and subtitle block.
struct EntityRow<Title: View, Subtitle: View, Icon: View, Accessory: View>: View {
    private let title: Title
    private let subtitle: Subtitle
    private let icon: Icon
    private let accessory: Accessory
    private let iconSize: CGFloat
    private let showsIcon: Bool
    private let style: EntityRowStyle

    init(style: EntityRowStyle = .compact, iconSize: CGFloat? = nil, showsIcon: Bool = true,
         @ViewBuilder title: () -> Title,
         @ViewBuilder subtitle: () -> Subtitle,
         @ViewBuilder icon: () -> Icon,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title()
        self.subtitle = subtitle()
        self.icon = icon()
        self.accessory = accessory()
        self.style = style
        self.iconSize = iconSize ?? (style == .card ? EntityCardStyle.iconSize : 22)
        self.showsIcon = showsIcon
    }

    var body: some View {
        HStack(alignment: .center, spacing: style == .card ? EntityCardStyle.contentSpacing : Spacing.md) {
            if showsIcon {
                icon.frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                title.font(.body).foregroundStyle(.primary).lineLimit(style == .card ? 2 : 1)
                subtitle.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: style == .card ? EntityCardStyle.iconSize : 0)
    }
}
