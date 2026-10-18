import SwiftUI

/// Native menus have compact artwork, independent of the row or preview's font.
/// The trigger keeps its own size; only the menu actions receive this environment.
struct AppMenu<Content: View, Label: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        if ApplePlatform.isDesktop {
            menu.buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden)
        } else { menu }
    }

    private var menu: some View {
        Menu {
            content().menuIconLayout()
        } label: {
            label()
        }
        .tint(.primary)
    }
}

extension AppMenu where Label == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.label = { Text(title) }
    }
}

extension View {
    func appContextMenu<Items: View>(@ViewBuilder menuItems: () -> Items) -> some View {
        contextMenu { menuItems().menuIconLayout() }
    }

    func appContextMenu<Items: View, Preview: View>(@ViewBuilder menuItems: () -> Items,
                                                  @ViewBuilder preview: () -> Preview) -> some View {
        contextMenu { menuItems().menuIconLayout() } preview: { preview() }
    }

    fileprivate func menuIconLayout() -> some View {
        environment(\.appIconContext, .menu)
            // Native action text and template icons stay neutral as app accents change.
            .tint(.primary)
            .foregroundStyle(.primary)
            .labelReservedIconWidth(AppIconMetrics.menuSize)
            .labelIconToTitleSpacing(ApplePlatform.isDesktop ? 6 : Spacing.sm)
            .font(ApplePlatform.isDesktop ? .system(size: 13) : .body)
    }
}
