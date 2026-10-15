import SwiftUI

/// A native destructive action for rows and menus. Swipe actions keep their native
/// white content on a red background and should use Button(role: .destructive).
struct DestructiveButton: View {
    private let title: String
    private let icon: AppIconName
    private let action: () -> Void

    init(_ title: String, icon: AppIconName, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(role: .destructive, action: action) {
            // The role colors the title; the label style also keeps artwork from
            // inheriting the app's accent, including inside native menus.
            Label(title, icon: icon)
                .foregroundStyle(Palette.danger)
        }
        .tint(Palette.danger)
    }
}
