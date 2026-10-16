#if targetEnvironment(macCatalyst)
import SwiftUI

/// The same desktop writing surface before and after the first message.
/// Callers own drafts, attachments, and actions through the shared chat services.
struct DesktopChatComposer<Editor: View, Controls: View>: View {
    @ViewBuilder var editor: () -> Editor
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            editor()
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            controls()
                .controlSize(.small)
                .frame(minHeight: 34)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .chromeGlass(.rect(cornerRadius: 24, style: .continuous))
    }
}
#endif
