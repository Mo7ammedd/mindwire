import SwiftUI

/// A single composer for the phone, desktop, and the first-message screen.
/// The caller supplies the real editor and actions; only chrome changes by platform.
struct ChatComposer<Editor: View, Leading: View, Trailing: View>: View {
    @ViewBuilder var editor: () -> Editor
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        GlassEffectContainer(spacing: Spacing.sm) {
            HStack(alignment: .bottom, spacing: Spacing.sm) {
                leading()
                HStack(alignment: .bottom, spacing: 6) {
                    editor()
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailing()
                }
                .padding(.leading, ApplePlatform.isDesktop ? 0 : Spacing.md)
                .padding(.trailing, ApplePlatform.isDesktop ? 0 : 5)
                .padding(.vertical, ApplePlatform.isDesktop ? 0 : 9)
                .modifier(ComposerGlass(visible: !ApplePlatform.isDesktop))
            }
            .padding(.leading, ApplePlatform.isDesktop ? 10 : 0)
            .padding(.trailing, ApplePlatform.isDesktop ? 8 : 0)
            .padding(.vertical, ApplePlatform.isDesktop ? 9 : 0)
            .modifier(ComposerGlass(visible: ApplePlatform.isDesktop))
        }
    }
}

/// Phone tools float beside the field; desktop tools sit within its single glass surface.
struct ChatComposerAccessoryGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if ApplePlatform.isDesktop { content }
        else { content.glassEffect(.regular.interactive(), in: .circle) }
    }
}

private struct ComposerGlass: ViewModifier {
    let visible: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if visible {
            content.chromeGlass(.rect(cornerRadius: Radius.xl, style: .continuous))
        } else {
            content
        }
    }
}
