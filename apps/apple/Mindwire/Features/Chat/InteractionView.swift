import SwiftUI

/// Unsent choices belong to the chat, so a non-blocking question can move from
/// the live response into history without clearing what the user is entering.
@MainActor @Observable
final class InteractionDraft {
    var answers: [String: DaemonQuestionAnswer] = [:]
    var text = ""
}

/// Renders a daemon-declared `DaemonInteraction` as a generic, dynamic prompt — the same shapes the
/// web shows: a checklist (todos), a plan/approval with buttons, a single-choice list, a multi-select
/// checklist, or a free-text input. The UI switches on `kind`, so a new kind still shows its
/// title/detail. When actionable, answers go to the pending request on the live run; prompts in
/// completed history are read-only except for daemon-owned async questions. Passive notices
/// use the same quiet disclosure as thinking; errors have bounded, on-demand details.
struct InteractionView: View {
    @Environment(\.chatAccent) private var accent
    let interaction: DaemonInteraction
    var showsTitle = true
    var actionable = false
    var submitting = false
    var draft: InteractionDraft? = nil
    var onAnswer: ((DaemonInteractionReply) -> Void)? = nil

    @State private var localDraft = InteractionDraft()
    private var values: InteractionDraft { draft ?? localDraft }

    private var needsResponse: Bool { interaction.needsResponse ?? false }
    private var options: [DaemonInteractionOption] { interaction.options ?? [] }
    private var isPassiveNotice: Bool {
        !needsResponse && interaction.meta?["asyncQuestion"] != .bool(true)
            && (interaction.kind == "warning" || interaction.kind == "info")
    }

    private var noticeTitle: String {
        if let title = interaction.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return t(interaction.kind == "warning" ? "chat.notice.warning" : "chat.notice.info")
    }

    var body: some View {
        if interaction.kind == "error" {
            ChatErrorDisclosure(title: interaction.title ?? t("chat.error.title"), detail: interaction.detail ?? "")
        } else if isPassiveNotice {
            ChatDetailDisclosure(text: interaction.detail ?? "") {
                Label(noticeTitle, icon: icon)
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if showsTitle, let title = interaction.title, !title.isEmpty {
                    Label(title, icon: icon)
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(interaction.kind == "error" ? Palette.danger : .primary)
                }
                content
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var content: some View {
        if !interaction.displayQuestions.isEmpty { questionsView }
        else if interaction.kind == "todos" { todosView }
        else { promptView }
    }

    // MARK: kinds

    private var todosView: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            detailLine
            ForEach(Array((interaction.items ?? []).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: Spacing.sm) {
                    AppIcon(todoIcon(item.status)).font(.caption)
                        .foregroundStyle(todoTint(item.status)).padding(.top, 2)
                    Text(item.content).font(.callout)
                        .strikethrough(item.status == "completed")
                        .foregroundStyle(item.status == "completed" ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var promptView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let d = interaction.detail, !d.isEmpty { MessageContentView(text: d) }
            if needsResponse, !options.isEmpty {
                if interaction.feedback == "always" || interaction.feedback == "rejection" {
                    TextField(interaction.feedback == "rejection" ? "Reason if rejecting (optional)" : "Feedback (optional)",
                              text: Binding(get: { values.text }, set: { values.text = $0 }), axis: .vertical)
                        .lineLimit(1...5).disabled(!canAnswer)
                }
                VStack(spacing: Spacing.xs) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                        optionButton(opt, prominent: i == 0)
                    }
                }
            }
        }
    }

    private var canAnswer: Bool { actionable && needsResponse && !submitting }

    private var questionsView: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ForEach(interaction.displayQuestions) { question in
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if let header = question.header, !header.isEmpty {
                        Text(header).font(.caption).foregroundStyle(.secondary)
                    }
                    if !showsTitle || interaction.displayQuestions.count > 1 || question.title != interaction.title {
                        Text(question.title).font(.callout.weight(.medium))
                    }
                    if question.multiSelect == true {
                        Text("Choose one or more").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array((question.options ?? []).enumerated()), id: \.offset) { _, option in
                        let id = option.id ?? option.label
                        let selected = answer(for: question.id).options.contains(id)
                        Button {
                            var answer = values.answers[question.id] ?? DaemonQuestionAnswer()
                            if selected { answer.options.removeAll { $0 == id } }
                            else if question.multiSelect == true { answer.options.append(id) }
                            else { answer.options = [id] }
                            values.answers[question.id] = answer
                        } label: {
                            HStack(alignment: .top, spacing: Spacing.sm) {
                                AppIcon(question.multiSelect == true
                                      ? (selected ? .checkSquare : .square)
                                      : (selected ? .checkCircleFilled : .circle))
                                    .foregroundStyle(selected ? accent : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.label).foregroundStyle(.primary)
                                    if let description = option.description, !description.isEmpty {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(!canAnswer)
                        if let preview = option.preview, !preview.isEmpty {
                            DisclosureGroup("Preview") { MessageContentView(text: preview) }
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if needsResponse {
                        let text = Binding<String>(get: { values.answers[question.id]?.text ?? "" }, set: { value in
                            var answer = values.answers[question.id] ?? DaemonQuestionAnswer()
                            answer.text = value
                            values.answers[question.id] = answer
                        })
                        if question.isSecret == true {
                            SecureField("Your answer", text: text).disabled(!canAnswer)
                        } else {
                            TextField((question.options ?? []).isEmpty ? "Your answer" : question.allowOther == true ? "Feedback or another answer" : "Feedback (optional)", text: text, axis: .vertical)
                                .lineLimit(1...5).disabled(!canAnswer)
                        }
                    } else if question.isSecret != true, !answer(for: question.id).text.isEmpty {
                        Text(answer(for: question.id).text).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if needsResponse {
                if interaction.isMessageQuestion {
                    Text("The agent can continue while you choose.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    if let questions = interaction.questions, !questions.isEmpty {
                        onAnswer?(DaemonInteractionReply(answers: values.answers))
                    } else if let question = interaction.displayQuestions.first {
                        let answer = values.answers[question.id] ?? DaemonQuestionAnswer()
                        onAnswer?(DaemonInteractionReply(options: answer.options, text: answer.text))
                    }
                } label: {
                    HStack {
                        if submitting { ProgressView() }
                        Text(t("chat.interaction.send"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canAnswer || !interaction.displayQuestions.allSatisfy { $0.accepts(values.answers[$0.id] ?? DaemonQuestionAnswer()) })
            } else if interaction.response != nil {
                Label("Answered", icon: .checkCircle)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func answer(for id: String) -> DaemonQuestionAnswer {
        if let response = interaction.response {
            if let answer = response.answers?[id] { return answer }
            if interaction.questions?.isEmpty != false, interaction.displayQuestions.first?.id == id {
                return DaemonQuestionAnswer(options: response.options ?? [], text: response.text ?? "")
            }
        }
        return values.answers[id] ?? DaemonQuestionAnswer()
    }

    @ViewBuilder private var detailLine: some View {
        if let d = interaction.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
    }

    private func optionButton(_ option: DaemonInteractionOption, prominent: Bool) -> some View {
        let decision = option.id ?? option.label
        let acceptsFeedback = interaction.feedback == "always" || (interaction.feedback == "rejection" && ["deny", "reject", "cancel"].contains(decision))
        let answer = DaemonInteractionReply(decision: decision, text: acceptsFeedback && !values.text.isEmpty ? values.text : nil)
        return Group {
            if prominent {
                Button { onAnswer?(answer) } label: { optionLabel(option) }
                    .buttonStyle(.glassProminent)
            } else {
                Button { onAnswer?(answer) } label: { optionLabel(option) }
                    .buttonStyle(.glass)
            }
        }
        .disabled(!canAnswer)
    }

    private func optionLabel(_ option: DaemonInteractionOption) -> some View {
        VStack(spacing: 3) {
            Text(option.label)
            if let description = option.description, !description.isEmpty {
                Text(description).font(.caption).opacity(0.7)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var icon: AppIconName { interaction.displayIcon }

    private func todoIcon(_ s: String?) -> AppIconName {
        switch s {
        case "completed":   return .checkCircleFilled
        case "in_progress": return .circleDashed
        default:            return .circle
        }
    }
    private func todoTint(_ s: String?) -> Color {
        switch s {
        case "completed":   return .green
        case "in_progress": return accent
        default:            return .secondary
        }
    }
}

extension DaemonInteraction {
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if let question = displayQuestions.first, !question.title.isEmpty { return question.title }
        return t(kind == "approval" ? "chat.interaction.approval" : "chat.interaction.question")
    }

    var displayIcon: AppIconName {
        switch kind {
        case "todos":            return .listCheck
        case "plan":             return .clipboardList
        case "approval":         return .shieldCheck
        case "choice", "select", "form": return .helpCircle
        case "input":            return .textCursor
        case "error", "warning": return .warning
        case "info":             return .info
        default:                 return .message
        }
    }
}

/// The transcript keeps a compact record; all answer controls live in the shared sheet.
struct InteractionSummaryView: View {
    let interaction: DaemonInteraction
    var onOpen: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) {
                    HStack {
                        summary
                        Spacer(minLength: Spacing.sm)
                        AppIcon(.chevronUp).font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
            } else {
                DisclosureGroup {
                    InteractionView(interaction: readOnlyInteraction, showsTitle: false)
                } label: {
                    summary
                }
            }
        }
        .tint(.primary)
        .foregroundStyle(.secondary)
        .padding(.vertical, Spacing.xs)
    }

    private var summary: some View {
        Label {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(interaction.displayTitle).font(.subheadline).lineLimit(2)
                Text(t(interaction.response != nil ? "chat.interaction.answered" :
                    onOpen != nil ? "chat.interaction.open" :
                    interaction.needsResponse == true
                        ? "chat.interaction.pending" : "chat.interaction.closed"))
                    .font(.caption)
            }
        } icon: {
            AppIcon(interaction.displayIcon)
        }
    }

    private var readOnlyInteraction: DaemonInteraction {
        var copy = interaction
        copy.needsResponse = false
        return copy
    }
}
