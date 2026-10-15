import SwiftUI

/// Errors start as one aligned row. Expanding never creates an unbounded transcript
/// cell; the complete, selectable diagnostic is available in a native sheet.
struct ChatErrorDisclosure: View {
    var title: String = t("chat.error.title")
    let detail: String
    var onDismiss: (() -> Void)? = nil
    @State private var expanded = false
    @State private var showingDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(detail.isEmpty ? title : detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .naturalChatDirection(detail, fillWidth: true)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(t("chat.error.details")) { showingDetails = true }
                        .font(.footnote.weight(.medium))
                        .tint(.primary)
                        .frame(minHeight: 36)
                        .accessibilityIdentifier("chat.error.details")
                }
                .padding(.leading, ChatContentStyle.iconWidth + Spacing.sm)
                .padding(.bottom, Spacing.xs)
            } label: {
                HStack(spacing: Spacing.sm) {
                    ChatToolIcon(symbol: .warning)
                    Text(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t("chat.error.title") : title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.danger)
                .frame(minHeight: 36)
            }
            .disclosureGroupStyle(ChatToolDisclosureStyle(identifier: "chat.error.toggle"))

            if let onDismiss {
                Button(action: onDismiss) { AppIcon(.close, size: 12).frame(width: 36, height: 36) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(t("chat.error.dismiss"))
                    .accessibilityIdentifier("chat.error.dismiss")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: detail) { expanded = false }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    Text(detail.isEmpty ? title : detail)
                        .font(.callout)
                        .naturalChatDirection(detail, fillWidth: true)
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .topBarLeading) {
                        Button { UIPasteboard.general.string = detail.isEmpty ? title : detail } label: {
                            Label(t("chat.copy"), icon: .copy)
                        }
                    }
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(t("common.done")) { showingDetails = false }
                    }
                }
            }
            .tint(.primary)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .accessibilityIdentifier("chat.error.sheet")
        }
    }
}
