import SwiftUI

/// Quiet, collapsed details shared by reasoning and passive agent notices in the live feed and history.
struct ChatDetailDisclosure<Label: View>: View {
    let text: String
    var metadata: String? = nil
    @ViewBuilder var label: () -> Label

    var body: some View {
        Group {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                heading
            } else {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(text)
                            .naturalChatDirection(text, fillWidth: true)
                            .font(.footnote)
                            .lineSpacing(4)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let metadata {
                            Text(metadata).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.xs)
                    .padding(.bottom, Spacing.sm)
                } label: {
                    heading
                }
                .font(.subheadline)
                .tint(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: some View {
        label()
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
    }
}
