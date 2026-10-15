import Foundation

/// An on-screen projection of the native owner, never a second conversation.
/// Epoch + sequence makes reconnects either exact replay or a full replacement.
struct NativeChatState {
    var activity: NativeSessionActivity?
    private(set) var connectionId: String?
    private(set) var sequence = 0
    private(set) var turnId: String?
    private(set) var projection = LiveTurn()
    private(set) var showingProjection = false
    private(set) var historyRequired = false
    private(set) var coversWholeTurn = true
    private(set) var pendingInputs: [DaemonUserInput] = []
    private var seenInputs: Set<String> = []
    private var inputOrder: [String] = []
    var connected = false

    var ownsConversation: Bool { activity?.owner == "native" }
    var isRunning: Bool { activity?.isRunning == true }
    var live: LiveTurn? { showingProjection ? projection : nil }
    var cursor: String? { connectionId.map { "\($0):\(sequence)" } }
    var interactionScope: String? { connectionId.map { "native:\($0):\(turnId ?? "")" } }
    var canSend: Bool { connected && activity?.capabilities.input == true }
    var canStop: Bool { connected && isRunning && activity?.capabilities.interrupt == true && activity?.turnId?.isEmpty == false }
    var canRespond: Bool { connected && activity?.capabilities.respond == true }

    @discardableResult
    mutating func apply(_ frame: NativeSessionFrame) throws -> Bool {
        if frame.type == "snapshot", let snapshot = frame.snapshot {
            if connectionId != snapshot.connectionId { seenInputs = []; inputOrder = [] }
            connectionId = snapshot.connectionId
            sequence = snapshot.sequence
            turnId = snapshot.turnId
            activity = snapshot.activity
            projection = LiveTurn(parts: snapshot.parts ?? [])
            showingProjection = snapshot.activity.isRunning && snapshot.turnId != nil || !projection.parts.isEmpty
            historyRequired = snapshot.historyRequired == true
            coversWholeTurn = snapshot.partial != true
            for input in snapshot.inputs ?? [] { rememberInput(input.id) }
            pendingInputs.removeAll { seenInputs.contains($0.id) }
            connected = true
            return historyRequired || !snapshot.activity.isRunning
        }
        if frame.type == "resume", let snapshot = frame.snapshot {
            guard connectionId == snapshot.connectionId, sequence == snapshot.sequence else {
                throw BackendError.message("The saved conversation cursor changed. Reconnect to refresh it.")
            }
            // A resume is a cursor acknowledgement, not a new projection.
            connected = true
            return false
        }
        guard frame.type == "update", let update = frame.update, update.connectionId == connectionId else {
            throw BackendError.message("The native conversation connection changed.")
        }
        guard update.sequence > sequence else { return false }
        guard update.sequence == sequence + 1 else {
            throw BackendError.message("Some conversation updates were missed. Reconnecting…")
        }
        sequence = update.sequence
        if update.reset == true {
            coversWholeTurn = update.partial != true
            projection = LiveTurn()
            showingProjection = update.turnId != nil
            historyRequired = false
        }
        if let id = update.turnId { turnId = id }
        if update.partial == true { coversWholeTurn = false }
        if let value = update.activity { activity = value }
        if let event = update.event {
            if let input = event.input {
                rememberInput(input.id)
                pendingInputs.removeAll { $0.id == input.id }
            }
            projection.apply(event)
            if !projection.parts.isEmpty { showingProjection = true }
        }
        historyRequired = historyRequired || update.historyChanged == true
        return update.historyChanged == true
    }

    mutating func accepted(_ input: DaemonUserInput) {
        guard !seenInputs.contains(input.id), !pendingInputs.contains(where: { $0.id == input.id }) else { return }
        pendingInputs.append(input)
    }

    private mutating func rememberInput(_ id: String) {
        guard seenInputs.insert(id).inserted else { return }
        inputOrder.append(id)
        if inputOrder.count > 512 { seenInputs.remove(inputOrder.removeFirst()) }
    }

    mutating func historyAdopted(_ messages: [DaemonMessage]) {
        guard !isRunning else { return }
        guard let turnId else {
            showingProjection = false
            historyRequired = false
            return
        }
        // A native file can finish flushing just after its completion event.
        // Keep the received output until history actually contains that answer.
        if Self.historyContains(projection, turnId: turnId, messages: messages) {
            showingProjection = false
            historyRequired = false
            for index in pendingInputs.indices where pendingInputs[index].isQueued {
                pendingInputs[index].status = "failed"
                pendingInputs[index].error = "The native turn ended before this input appeared. Check its terminal before retrying."
            }
        }
    }

    static func historyContains(_ projection: LiveTurn, turnId: String, messages: [DaemonMessage]) -> Bool {
        let native = messages.filter { $0.nativeTurnId == turnId && !$0.id.hasPrefix("native-turn:") }
        let text = normalized(projection.text)
        return text.isEmpty
            ? native.contains { $0.role == .assistant } || projection.parts.isEmpty
            : normalized(native.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")).contains(text)
    }

    /// Very large native turns deliberately retain only a recent item window.
    /// Prepend the already loaded prefix and replace its overlap with live items.
    func live(in history: [DaemonMessage]) -> LiveTurn? {
        guard showingProjection else { return nil }
        guard !coversWholeTurn, let turnId else { return projection }
        var prefix: [DaemonMessagePart] = []
        for message in history where message.nativeTurnId == turnId {
            if message.role == .user {
                prefix.append(.init(kind: .user, input: .init(id: message.id, text: message.text,
                    attachments: message.attachments, createdAt: message.createdAt, status: "accepted")))
            } else if let parts = message.parts, !parts.isEmpty { prefix += parts }
            else if !message.text.isEmpty { prefix.append(.init(kind: .text, text: message.text)) }
        }
        if let first = projection.parts.first, let overlap = prefix.lastIndex(where: { Self.sameItem($0, first) }) {
            prefix.removeSubrange(overlap...)
        }
        var result = LiveTurn(parts: prefix + projection.parts)
        result.error = projection.error
        result.result = projection.result
        result.statusMessage = projection.statusMessage
        return result
    }

    private static func sameItem(_ a: DaemonMessagePart, _ b: DaemonMessagePart) -> Bool {
        guard a.kind == b.kind else { return false }
        if let id = a.id, id == b.id { return true }
        if let id = a.tool?.id, !id.isEmpty, id == b.tool?.id { return true }
        if let input = a.input, let other = b.input {
            return input.id == other.id || input.text == other.text && input.attachments == other.attachments
        }
        if let text = a.text, !text.isEmpty, let other = b.text { return normalized(text) == normalized(other) }
        return false
    }

    private static func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    mutating func dismissInput(_ id: String) { pendingInputs.removeAll { $0.id == id } }
    mutating func resetCursor() { connectionId = nil; sequence = 0 }
}
