import SwiftUI

extension View {
    /// Centered monochrome Oblien mark in the nav bar — the app's signature header on tab
    /// roots. Inline title mode; the mark occupies the center while the navigationTitle
    /// stays set (used as the back-button label when pushing).
    func principalBrand(visible: Bool = true) -> some View {
        modifier(PrincipalBrand(visible: visible))
    }

    /// Native single-field input dialog (rename, expose port, …).
    func inputDialog(
        titleKey: String,
        isPresented: Binding<Bool>,
        text: Binding<String>,
        placeholder: String = "",
        confirmKey: String = "common.save",
        onSubmit: @escaping () -> Void
    ) -> some View {
        self.alert(t(titleKey), isPresented: isPresented) {
            TextField(placeholder, text: text)
            Button(t(confirmKey)) { onSubmit() }
            Button(t("common.cancel"), role: .cancel) {}
        }
    }
}

private struct PrincipalBrand: ViewModifier {
    let visible: Bool
    @Environment(\.sidebarNavigation) private var sidebar

    func body(content: Content) -> some View {
        content.toolbarTitleDisplayMode(.inline)
            .toolbar {
                if visible && sidebar == nil {
                    ToolbarItem(placement: .principal) { OblienMark(size: 48, color: .primary) }
                }
            }
    }
}
