import Foundation

/// Keep ordered input, while replacing only pointer motion that has not been sent.
/// Clicks, button transitions and keyboard events are never reordered or replayed.
struct DesktopInputBuffer {
    static let capacity = 32
    private(set) var pending: [DesktopInput] = []
    private var pointerButtons = 0
    private var lastPointerWasTransition = false
    var isEmpty: Bool { pending.isEmpty }

    mutating func append(contentsOf inputs: [DesktopInput]) -> Bool {
        var updated = self
        for input in inputs where !updated.append(input) { return false }
        self = updated
        return true
    }

    mutating func append(_ input: DesktopInput) -> Bool {
        let isTransition = input.kind == "pointer" && (input.buttons ?? 0) != pointerButtons
        if let last = pending.last {
            if input.kind == "pointer", last.kind == "pointer", input.buttons == last.buttons,
               !isTransition, !lastPointerWasTransition {
                pending[pending.count - 1] = input
                return true
            }
            if input.kind == "scroll", last.kind == "scroll", input.x == last.x, input.y == last.y {
                let dx = (input.deltaX ?? 0) + (last.deltaX ?? 0)
                let dy = (input.deltaY ?? 0) + (last.deltaY ?? 0)
                // Bound a coalesced wheel event to the service's protocol limit.
                if abs(dx) <= 50, abs(dy) <= 50 {
                    var combined = last; combined.deltaX = dx; combined.deltaY = dy
                    pending[pending.count - 1] = combined
                    return true
                }
            }
            if input.kind == "text", last.kind == "text", input.textMode == last.textMode,
               let old = last.text, let new = input.text, old.utf8.count + new.utf8.count <= 4096 {
                var combined = last
                combined.text = old + new
                pending[pending.count - 1] = combined
                return true
            }
        }
        // Reserve one slot for a mouse-up even behind a full typing/click queue.
        // Dropping that transition would leave a drag held while the lease renews.
        let releasesMouse = input.releasesButtons
        guard pending.count < (releasesMouse ? Self.capacity : Self.capacity - 1) else { return false }
        pending.append(input)
        if input.kind == "pointer" { pointerButtons = input.buttons ?? 0 }
        if input.kind == "release" { pointerButtons = 0 }
        lastPointerWasTransition = isTransition
        return true
    }
    mutating func next() -> DesktopInput? { pending.isEmpty ? nil : pending.removeFirst() }
    mutating func removeAll() { pending.removeAll(); pointerButtons = 0; lastPointerWasTransition = false }
}

/// A foreground return restores only a requested connection. Control acquisition
/// is separately guarded by the user's current intent and a free server lease.
struct DesktopConnectionLifecycle {
    private(set) var requested = false
    private(set) var suspended = false
    mutating func connect() { requested = true; suspended = false }
    mutating func background() -> Bool {
        guard requested, !suspended else { return false }
        suspended = true
        return true
    }
    mutating func resume() -> Bool {
        guard requested, suspended else { return false }
        suspended = false
        return true
    }
    mutating func disconnect() { requested = false; suspended = false }
}

enum DesktopReconnectPolicy {
    static func code(_ error: Error) -> String? {
        (error as? DesktopProblem)?.code ?? (error as? DaemonHTTPError)?.code
    }
    static func requiresSetup(_ error: Error) -> Bool {
        guard let code = code(error) else { return false }
        return ["desktop_setup_required", "screen_sharing_off", "desktop_authentication", "desktop_credentials", "desktop_auth_protocol"].contains(code)
    }
    static func shouldRetry(_ error: Error) -> Bool {
        if error.isRequestCancellation || requiresSetup(error) { return false }
        if let connection = error as? ComputerConnectionError { return connection.canRetryConnection }
        if error is SSHIdentityError || error is SSHAuthenticationError { return false }
        if case BackendError.unreachable = error { return true }
        if let code = code(error) {
            if ["disconnected", "unavailable", "preparing", "timeout", "restarted", "not_found", "session_expired", "desktop_session_expired", "needs_authorization"].contains(code) { return true }
        }
        if let http = error as? DaemonHTTPError { return http.status >= 500 || http.status == 408 || http.status == 429 }
        return (error as NSError).domain == NSURLErrorDomain
    }
    static func delay(attempt: Int) -> Double { min(15, pow(2, Double(max(0, min(4, attempt - 1))))) }
}

enum DesktopTyping {
    /// QEMU's Mac keyboard needs physical US keys plus Shift for capitals/symbols.
    /// Composed Unicode goes through the existing native text/clipboard path.
    static func key(for character: Character) -> [String]? {
        if character == "\n" || character == "\r\n" { return ["Enter"] }
        if character == "\t" { return ["Tab"] }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
              (32...126).contains(scalar.value) else { return nil }
        let upper = Array("~!@#$%^&*()_+{}|:\"<>?")
        let lower = Array("`1234567890-=[]\\;',./")
        if let index = upper.firstIndex(of: character) { return ["Shift", String(lower[index])] }
        if (65...90).contains(scalar.value) { return ["Shift", String(character).lowercased()] }
        return [String(character)]
    }

    static func inputs(_ text: String, modifiers: [String] = [], keyboardText: Bool) -> [DesktopInput] {
        var result: [DesktopInput] = []
        for character in text {
            if let keys = key(for: character) {
                if modifiers.isEmpty, keyboardText, character != "\n", character != "\t", character != "\r\n" {
                    if result.last?.textMode == "keyboard", (result.last?.text?.utf8.count ?? 0) < 4096 {
                        result[result.count - 1].text! += String(character)
                    } else {
                        result.append(.init(kind: "text", text: String(character), textMode: "keyboard"))
                    }
                } else {
                    let chord = (modifiers + keys).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    result.append(.init(kind: "key", keys: chord))
                }
            } else if result.last?.kind == "text", result.last?.textMode == nil {
                result[result.count - 1].text! += String(character)
            } else {
                result.append(.init(kind: "text", text: String(character)))
            }
        }
        return result
    }
}
