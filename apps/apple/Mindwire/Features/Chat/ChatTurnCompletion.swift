import Foundation

/// Reconcile the exact run, streamed components and refreshed history in one step. Native
/// transcripts use different message IDs from the daemon's recorded reply, so both identity
/// and the run's start time are considered before touching an assistant row.
struct ChatTurnCompletion {
    var messages: [DaemonMessage]
    var error: String?

    static func containsReply(_ messages: [DaemonMessage], for run: DaemonRun) -> Bool {
        messages.contains { message in
            message.role == .assistant && (message.id == run.replyId || atOrAfter(message.createdAt, run.createdAt))
        }
    }

    static func reconcile(current: [DaemonMessage], fetched: [DaemonMessage]?, live: LiveTurn,
                          run: DaemonRun?, runId: String, baselineIDs: Set<String>,
                          pendingUser: DaemonMessage?, transportError: String? = nil) -> Self {
        var messages = fetched ?? current
        let followups = live.parts.compactMap { $0.kind == .user ? $0.input : nil }
        if !followups.isEmpty, !containsInputs(followups, messages: messages, run: run) {
            // A lagging or unavailable history read must keep every accepted
            // user boundary. Recover the streamed turn, then use normal final
            // response reconciliation for its last segment.
            return recoverInputs(current: current, fetched: fetched, live: live, run: run, runId: runId,
                                 pendingUser: pendingUser, transportError: transportError)
        }
        if let pendingUser, !messages.contains(where: { $0.role == .user && $0.text == pendingUser.text &&
            ($0.id == pendingUser.id || !baselineIDs.contains($0.id)) }) {
            // A history read can lag the accepted turn. Keep the optimistic bubble until it catches up.
            // An earlier identical question must not consume this turn's bubble.
            // A byte-bounded page can begin with the reply. Keep the optimistic input
            // before that reply, never underneath it, until its native ID is fetched.
            let index = messages.firstIndex { atOrAfter($0.createdAt, pendingUser.createdAt) } ?? messages.endIndex
            messages.insert(pendingUser, at: index)
        }
        let lastUser = messages.lastIndex(where: { $0.role == .user }) ?? -1
        let reply = messages.indices.last { i in
            let message = messages[i]
            guard message.role == .assistant else { return false }
            if let replyId = run?.replyId, message.id == replyId { return true }
            return i > lastUser && (!baselineIDs.contains(message.id) ||
                (run.map { atOrAfter(message.createdAt, $0.createdAt) } ?? false))
        }

        var error: String?
        switch run?.status {
        case .error:
            error = nonempty(run?.error) ?? nonempty(live.error) ?? t("chat.turnError")
        case .done, .cancelled:
            error = nil
        default:
            error = nonempty(transportError) ?? nonempty(live.error)
        }

        var parts = live.parts.filter { $0.kind != .user }
        if let reply {
            if !parts.isEmpty {
                // Compaction can split a native turn into several messages. Components already
                // present before the final reply must not be copied into that reply again.
                // Steering an async answer creates another native user message inside
                // this same run. Its streamed snapshot still includes the earlier form
                // and commentary, already present before that user-message boundary.
                let questionIDs = Set(parts.compactMap { part -> String? in
                    guard let question = part.interaction, question.isMessageQuestion,
                          question.runId == runId else { return nil }
                    return question.id
                })
                var prefixStart = lastUser + 1
                if !followups.isEmpty {
                    // All native responses within this run precede the final
                    // reply, including responses before a queued user message.
                    prefixStart = messages.firstIndex { message in
                        message.role == .assistant && (run.map { atOrAfter(message.createdAt, $0.createdAt) }
                            ?? !baselineIDs.contains(message.id))
                    } ?? prefixStart
                }
                if !questionIDs.isEmpty, let i = messages[..<reply].firstIndex(where: { message in
                    message.parts?.contains { part in
                        guard let question = part.interaction, question.runId == runId, let id = question.id else { return false }
                        return questionIDs.contains(id)
                    } == true
                }) { prefixStart = min(prefixStart, i) }
                var earlier = messages[..<reply].dropFirst(prefixStart).filter { $0.role != .user }.flatMap { message in
                    message.parts ?? (message.text.isEmpty ? [] : [.init(kind: .text, text: message.text)])
                }
                parts.removeAll { preview in
                    guard let i = earlier.firstIndex(where: { matches($0, preview) }) else { return false }
                    earlier.remove(at: i)
                    return true
                }
                var committed = messages[reply].parts ?? []
                if committed.isEmpty, !messages[reply].text.isEmpty {
                    committed = [.init(kind: .text, text: messages[reply].text)]
                }
                messages[reply].parts = merge(committed: committed, streamed: parts,
                    preferStreamedText: run?.status == .cancelled || run?.status == .running)
            }
        } else if !parts.isEmpty {
            messages.append(DaemonMessage(id: "run-\(runId)", chatId: run?.chatId ?? pendingUser?.chatId ?? current.last?.chatId ?? "",
                                          role: .assistant, text: live.text, createdAt: run?.endedAt ?? isoNow(), parts: parts))
        }

        let hasReply = reply.map { !messages[$0].text.isEmpty || messages[$0].parts?.isEmpty == false } ?? !parts.isEmpty
        if run?.status == .done, !hasReply {
            error = nonempty(transportError) ?? t("chat.noResponse")
        }
        if let error {
            let failure = DaemonMessagePart(kind: .interaction,
                interaction: DaemonInteraction(id: "run-\(runId)-error", kind: "error", title: t("chat.error.title"), detail: error))
            if let reply {
                parts = messages[reply].parts ?? (messages[reply].text.isEmpty ? [] : [.init(kind: .text, text: messages[reply].text)])
                if !parts.contains(where: { $0.interaction?.id == failure.interaction?.id ||
                    ($0.interaction?.kind == "error" && $0.interaction?.detail == error) }) { parts.append(failure) }
                messages[reply].parts = parts
            } else if messages.last?.id == "run-\(runId)" {
                messages[messages.count - 1].parts?.append(failure)
            } else if !messages.contains(where: { $0.id == "run-\(runId)-error" }) {
                messages.append(DaemonMessage(id: "run-\(runId)-error", chatId: run?.chatId ?? pendingUser?.chatId ?? current.last?.chatId ?? "",
                                              role: .assistant, text: "", createdAt: run?.endedAt ?? isoNow(), parts: [failure]))
            }
        }
        return Self(messages: messages, error: error)
    }

    /// Claude can merge consecutive queued prompts into a single native user
    /// message. Consume text occurrences in order, without matching an earlier
    /// identical prompt or inserting duplicates beside that native message.
    private static func containsInputs(_ inputs: [DaemonUserInput], messages: [DaemonMessage], run: DaemonRun?) -> Bool {
        var users = messages.filter { message in
            message.role == .user && (run.map { atOrAfter(message.createdAt, $0.createdAt) } ?? true)
        }
        // The first user entry after admission is the original prompt.
        if let first = users.first, !inputs.contains(where: { "input-\($0.id)" == first.id }),
           let date = RelativeTime.date(first.createdAt),
           let inputDate = inputs.first.flatMap({ RelativeTime.date($0.createdAt) }), date < inputDate {
            users.removeFirst()
        }
        var index = 0
        var remaining = users.map(\.text)
        var images = users.map { $0.attachments?.count ?? 0 }
        for input in inputs {
            var found = false
            while index < users.count {
                let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let count = input.attachments?.count ?? 0
                if text.isEmpty {
                    if count > 0 && images[index] >= count { images[index] -= count; found = true; break }
                } else if let range = remaining[index].range(of: text), images[index] >= count {
                    remaining[index] = String(remaining[index][range.upperBound...])
                    images[index] -= count
                    found = true
                    break
                }
                index += 1
            }
            if !found { return false }
        }
        return true
    }

    private static func recoverInputs(current: [DaemonMessage], fetched: [DaemonMessage]?, live: LiveTurn,
                                      run: DaemonRun?, runId: String, pendingUser: DaemonMessage?, transportError: String?) -> Self {
        let source = fetched ?? current
        let start = source.firstIndex { message in run.map { atOrAfter(message.createdAt, $0.createdAt) } ?? false } ?? source.endIndex
        var prefix = Array(source[..<start])
        let firstInput = live.parts.compactMap(\.input).first
        let original = pendingUser ?? source[start...].first { message in
            guard message.role == .user else { return false }
            guard let inputDate = firstInput.flatMap({ RelativeTime.date($0.createdAt) }),
                  let date = RelativeTime.date(message.createdAt) else { return true }
            return date < inputDate
        }
        if let original, !prefix.contains(where: { $0.id == original.id }) { prefix.append(original) }
        var segment: [DaemonMessagePart] = []
        let chatID = run?.chatId ?? original?.chatId ?? current.last?.chatId ?? ""
        func appendSegment() {
            guard !segment.isEmpty else { return }
            prefix.append(DaemonMessage(id: "run-\(runId)-segment-\(prefix.count)", chatId: chatID, role: .assistant,
                text: segment.compactMap { $0.kind == .text ? $0.text : nil }.joined(separator: "\n\n"),
                createdAt: run?.createdAt ?? isoNow(), parts: segment))
            segment = []
        }
        for part in live.parts {
            if part.kind == .user, let input = part.input {
                appendSegment()
                prefix.append(input.message(chatId: chatID))
            } else { segment.append(part) }
        }
        var tail = live
        tail.parts = segment
        return reconcile(current: prefix, fetched: nil, live: tail, run: run, runId: runId,
                         baselineIDs: Set(prefix.map(\.id)), pendingUser: nil, transportError: transportError)
    }

    /// History owns final snapshots. Add components it omitted, matching by item/tool/request ID
    /// and using text overlap for older transcripts without IDs. A longer replay is not necessarily
    /// more complete than history (it may contain only a tool's start or a partial answer).
    private static func merge(committed: [DaemonMessagePart], streamed: [DaemonMessagePart], preferStreamedText: Bool) -> [DaemonMessagePart] {
        var parts = committed
        var cursor = 0
        for preview in streamed {
            if let i = parts.indices.dropFirst(cursor).first(where: { matches(parts[$0], preview) }) {
                var part = parts[i]
                part.durationMs = part.durationMs ?? preview.durationMs
                part.tokens = part.tokens ?? preview.tokens
                part.id = part.id ?? preview.id
                if preferStreamedText, let text = preview.text, text.hasPrefix(part.text ?? "") {
                    part.text = text // An interrupted native snapshot may lag its last emitted token.
                }
                if var tool = part.tool, let streamedTool = preview.tool {
                    tool.name = tool.name ?? streamedTool.name
                    tool.input = tool.input ?? streamedTool.input
                    tool.action = tool.action ?? streamedTool.action
                    tool.output = tool.output ?? streamedTool.output
                    tool.isError = tool.isError ?? streamedTool.isError
                    part.tool = tool
                }
                parts[i] = part
                cursor = i + 1
            } else {
                parts.insert(preview, at: cursor)
                cursor += 1
            }
        }
        return parts
    }

    private static func matches(_ final: DaemonMessagePart, _ preview: DaemonMessagePart) -> Bool {
        guard final.kind == preview.kind else { return false }
        func identity(_ part: DaemonMessagePart) -> String? {
            nonempty(part.id) ?? nonempty(part.tool?.id) ?? nonempty(part.interaction?.id)
        }
        let finalID = identity(final), previewID = identity(preview)
        if let a = finalID, let b = previewID {
            if a == b { return true }
            // A saved transcript can assign a different ID to the exact same streamed reply.
            // Pair equal text chronologically; retain distinct repeated items within each source.
            if final.kind != .text && final.kind != .thinking { return false }
        }
        switch final.kind {
        case .text, .thinking:
            guard let a = final.text?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty,
                  let b = preview.text?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return false }
            return a == b || (finalID == nil || previewID == nil) && (a.hasPrefix(b) || b.hasPrefix(a))
        case .tool:
            return final.tool?.name == preview.tool?.name && final.tool?.input == preview.tool?.input
        case .interaction:
            return final.interaction?.kind == preview.interaction?.kind && final.interaction?.detail == preview.interaction?.detail
        case .compaction:
            return final.compaction == preview.compaction || nonempty(preview.compaction?.summary) == nil
        case .user:
            return final.input?.id == preview.input?.id
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    static func atOrAfter(_ value: String, _ reference: String) -> Bool {
        func date(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        guard let value = date(value), let reference = date(reference) else { return false }
        return value >= reference
    }
}
