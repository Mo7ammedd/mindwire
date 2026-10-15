import SwiftUI

/// The same artwork, spacing, and surface scale across the three library tabs.
enum EntityCardStyle {
    static let iconSize: CGFloat = 44
    static let iconCornerRadius: CGFloat = 12
    static let contentSpacing: CGFloat = 16
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
    static let cornerRadius: CGFloat = 26
}

struct EntityCardBackground: View {
    var selected = false

    var body: some View {
        RoundedRectangle(cornerRadius: EntityCardStyle.cornerRadius, style: .continuous)
            .fill(Palette.surface)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: EntityCardStyle.cornerRadius, style: .continuous)
                        .fill(Palette.accent.opacity(0.12))
                }
            }
    }
}

/// Transparent harness and OS marks get the same visual footprint as project artwork.
struct EntityCardIcon<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: EntityCardStyle.iconSize, height: EntityCardStyle.iconSize)
            .background(Palette.surfaceAlt, in: .rect(cornerRadius: EntityCardStyle.iconCornerRadius))
            .accessibilityHidden(true)
    }
}

private struct EntityCardRow: ViewModifier {
    let selected: Bool
    let spacing: CGFloat

    func body(content: Content) -> some View {
        content
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: EntityCardStyle.padding + spacing / 2,
                                     leading: EntityCardStyle.padding,
                                     bottom: EntityCardStyle.padding + spacing / 2,
                                     trailing: EntityCardStyle.padding))
            .listRowBackground(EntityCardBackground(selected: selected).padding(.vertical, spacing / 2))
    }
}

extension View {
    /// `spacing` adds a gutter between cards sharing a native, reorderable List section.
    func entityCardRow(selected: Bool = false, spacing: CGFloat = 0) -> some View {
        modifier(EntityCardRow(selected: selected, spacing: spacing))
    }
}
