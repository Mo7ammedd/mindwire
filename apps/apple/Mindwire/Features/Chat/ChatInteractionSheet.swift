import SwiftUI

/// A single control above the composer keeps requests reachable while the transcript scrolls.
struct ChatInteractionButton: View {
    let requests: [ChatInteractionRequest]
    let open: () -> Void

    var body: some View {
        if let first = requests.first {
            Button(action: open) {
                HStack(spacing: Spacing.sm) {
                    AppIcon(first.interaction.displayIcon)
                        .font(.body)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(first.interaction.displayTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        Text(requests.count == 1 ? t("chat.interaction.open") :
                            t("chat.interaction.pendingCount", ["count": String(requests.count)]))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Spacing.sm)
                    AppIcon(.chevronUp)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.xs)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: Radius.lg))
            .tint(.primary)
            .accessibilityIdentifier("chat.pendingInteractions")
        }
    }
}

/// Both blocking native requests and async questions use the same daemon-backed answer controls.
/// Dismissing keeps drafts in the chat; successful acknowledgement advances or closes the sheet.
struct ChatInteractionSheet: View {
    let model: ChatModel
    @Binding var selectedID: ChatInteractionRequest.ID?
    @Environment(\.dismiss) private var dismiss

    private var requests: [ChatInteractionRequest] { model.pendingInteractions }
    private var submitting: Bool { !model.respondingInteractions.isEmpty }

    var body: some View {
        let current = requests.first { $0.id == selectedID } ?? requests.first
        NavigationStack {
            Form {
                if let error = model.turnError {
                    Section {
                        ChatErrorDisclosure(detail: error) { model.turnError = nil }
                    }
                }
                if requests.count > 1 {
                    Section {
                        Picker(t("chat.interaction.request"), selection: Binding(
                            get: { current?.id }, set: { selectedID = $0 }
                        )) {
                            ForEach(requests) { request in
                                Text(request.interaction.displayTitle).tag(Optional(request.id))
                            }
                        }
                        .disabled(submitting)
                    }
                }
                if let request = current {
                    Section {
                        InteractionView(interaction: request.interaction,
                            showsTitle: request.interaction.displayQuestions.isEmpty,
                            actionable: !model.preparing && !model.loadingHistory,
                            submitting: model.respondingInteractions.contains(request.id.interactionId),
                            draft: model.interactionDraft(for: request.interaction),
                            onAnswer: { answer in
                                Task { await model.respond(to: request.interaction, answer: answer) }
                            })
                            .id(request.id)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(t("chat.interaction.sheetTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button(t("common.done")) { dismiss() }
                        .tint(.primary)
                        .disabled(submitting)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(submitting)
        .onChange(of: requests.map(\.id)) { _, ids in
            if ids.isEmpty { dismiss() }
            else if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
        }
    }
}
