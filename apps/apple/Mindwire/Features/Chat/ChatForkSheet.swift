import SwiftUI
import Observation

/// One branch receipt and one send receipt survive an interrupted attempt.
@MainActor @Observable
final class ChatForkDraft: Identifiable {
    struct Submission: Equatable {
        let sourceMessageId: String
        let chatId: String
        let requestId: String
        let text: String
        let attachments: [DaemonAttachment]
    }

    let id = UUID()
    let message: DaemonMessage
    var text: String
    private(set) var submitting = false
    private(set) var error: String?
    private(set) var submitted: Submission?
    private(set) var completedChatId: String?
    @ObservationIgnored private let perform: (Submission) async throws -> String

    init(message: DaemonMessage, perform: @escaping (Submission) async throws -> String) {
        self.message = message
        self.text = message.text
        self.perform = perform
    }

    var canSubmit: Bool {
        !submitting && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(message.attachments ?? []).isEmpty)
    }

    @discardableResult
    func send() async -> String? {
        guard canSubmit else { return nil }
        if let completedChatId { return completedChatId }
        submitting = true
        error = nil
        defer { submitting = false }
        let request = submitted ?? Submission(sourceMessageId: message.id, chatId: newId(), requestId: UUID().uuidString,
                                               text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: message.attachments ?? [])
        submitted = request
        do {
            let chatId = try await perform(request)
            completedChatId = chatId
            return chatId
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

struct ChatForkSheet: View {
    @Bindable var draft: ChatForkDraft
    let onSent: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft.text)
                        .naturalChatDirection(draft.text)
                        .frame(minHeight: 160, maxHeight: 300)
                        .focused($editing)
                        .disabled(draft.submitted != nil)
                        .accessibilityLabel(t("chat.fork.message"))
                    if let attachments = draft.message.attachments, !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: Spacing.sm) {
                                ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                                    ChatImageThumbnail(attachment: attachment)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                } footer: {
                    Text(t("chat.fork.detail"))
                }
                if let error = draft.error {
                    Section { Text(error).foregroundStyle(.red) } footer: { Text(t("chat.fork.retryDetail")) }
                }
            }
            .navigationTitle(t("chat.fork.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(t("common.cancel")) { dismiss() }.disabled(draft.submitting)
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button {
                        editing = false
                        Task { if let id = await draft.send() { onSent(id) } }
                    } label: {
                        if draft.submitting { ProgressView() }
                        else { Text(t(draft.error == nil ? "common.send" : "common.retry")) }
                    }
                    .disabled(draft.canSubmit == false)
                    .accessibilityLabel(t("chat.fork.title"))
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(draft.submitting)
    }
}
