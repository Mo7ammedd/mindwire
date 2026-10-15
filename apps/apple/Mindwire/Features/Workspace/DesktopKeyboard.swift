import SwiftUI
import UIKit

enum DesktopKeyboardEvent: Equatable {
    case text(String)
    case key([String])
}

/// A native input client, not a local message composer. UIKit owns IME and
/// dictation; only committed text is forwarded. Nothing waits for a Send button.
struct DesktopKeyboard: UIViewRepresentable {
    @Binding var visible: Bool
    var send: (DesktopKeyboardEvent) -> Void

    func makeUIView(context: Context) -> DesktopKeyboardView { DesktopKeyboardView() }
    func updateUIView(_ view: DesktopKeyboardView, context: Context) {
        view.send = send
        view.onDismiss = { visible = false }
        if visible, !view.isFirstResponder {
            // Wait until SwiftUI has attached the input client to its window.
            view.wantsKeyboard = true
            view.requestKeyboard()
        } else if !visible {
            view.wantsKeyboard = false
            if view.isFirstResponder { view.resignFirstResponder() }
            view.resetBuffer()
        }
    }
    static func dismantleUIView(_ view: DesktopKeyboardView, coordinator: ()) {
        view.wantsKeyboard = false; view.send = nil; view.onDismiss = nil
        view.resignFirstResponder(); view.resetBuffer()
    }
}

final class DesktopKeyboardView: UITextView, UITextViewDelegate {
    var send: ((DesktopKeyboardEvent) -> Void)?
    var onDismiss: (() -> Void)?
    var wantsKeyboard = false
    private var changingMarkedText = false
    private var handledPresses = Set<UIPress>()
    private static let sentinel = "\u{200B}"

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        backgroundColor = .clear; textColor = .clear; tintColor = .clear
        isScrollEnabled = false; isAccessibilityElement = false
        autocorrectionType = .no; autocapitalizationType = .none; spellCheckingType = .no
        smartQuotesType = .no; smartDashesType = .no; smartInsertDeleteType = .no
        keyboardType = .default; returnKeyType = .default
        inputAssistantItem.leadingBarButtonGroups = []; inputAssistantItem.trailingBarButtonGroups = []
        resetBuffer()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() { super.didMoveToWindow(); requestKeyboard() }
    func requestKeyboard() {
        guard wantsKeyboard, window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }
    func resetBuffer() {
        guard markedTextRange == nil else { return }
        text = Self.sentinel; selectedRange = NSRange(location: 1, length: 0)
        undoManager?.removeAllActions()
    }
    func textViewDidChange(_ textView: UITextView) { flushCommittedText() }
    func textViewDidEndEditing(_ textView: UITextView) {
        if wantsKeyboard { wantsKeyboard = false; onDismiss?() }
    }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        changingMarkedText = true
        super.setMarkedText(markedText, selectedRange: selectedRange)
        changingMarkedText = false
    }
    override func unmarkText() {
        super.unmarkText()
        flushCommittedText()
    }
    override func insertText(_ text: String) {
        super.insertText(text)
        flushCommittedText()
    }
    override func deleteBackward() {
        if markedTextRange == nil, text == Self.sentinel || text.isEmpty {
            send?(.key(["Backspace"]))
            resetBuffer()
        } else {
            super.deleteBackward()
        }
    }
    private func flushCommittedText() {
        guard !changingMarkedText, markedTextRange == nil else { return }
        var committed = text ?? ""
        if committed.hasPrefix(Self.sentinel) { committed.removeFirst() }
        guard !committed.isEmpty else { resetBuffer(); return }
        send?(.text(committed))
        resetBuffer()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if markedTextRange != nil { super.pressesBegan(presses, with: event); return }
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, let chord = Self.chord(key) {
                handledPresses.insert(press); send?(.key(chord))
            } else { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.subtracting(handledPresses)
        handledPresses.subtract(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.subtracting(handledPresses)
        handledPresses.subtract(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }
    private static func chord(_ key: UIKey) -> [String]? {
        let special: [UIKeyboardHIDUsage: String] = [
            .keyboardEscape: "Escape", .keyboardTab: "Tab", .keyboardReturnOrEnter: "Enter",
            .keyboardDeleteOrBackspace: "Backspace", .keyboardDeleteForward: "Delete",
            .keyboardLeftArrow: "Left", .keyboardRightArrow: "Right", .keyboardUpArrow: "Up", .keyboardDownArrow: "Down",
            .keyboardHome: "Home", .keyboardEnd: "End", .keyboardPageUp: "PageUp", .keyboardPageDown: "PageDown",
            .keyboardInsert: "Insert", .keyboardCapsLock: "CapsLock"
        ]
        var modifiers: [String] = []
        let flags = key.modifierFlags
        if flags.contains(.control) { modifiers.append("Ctrl") }
        if flags.contains(.alternate) { modifiers.append("Alt") }
        if flags.contains(.command) { modifiers.append("Meta") }
        let function = key.keyCode.rawValue
        let f1 = UIKeyboardHIDUsage.keyboardF1.rawValue
        let f12 = UIKeyboardHIDUsage.keyboardF12.rawValue
        let f13 = UIKeyboardHIDUsage.keyboardF13.rawValue
        let f24 = UIKeyboardHIDUsage.keyboardF24.rawValue
        var name = special[key.keyCode]
        if (f1...f12).contains(function) { name = "F\(function - f1 + 1)" }
        if (f13...f24).contains(function) { name = "F\(function - f13 + 13)" }
        if name == nil, !modifiers.isEmpty, !key.charactersIgnoringModifiers.isEmpty {
            name = key.charactersIgnoringModifiers
        }
        guard let name else { return nil }
        if flags.contains(.shift) { modifiers.append("Shift") }
        return modifiers + [name]
    }
}

struct DesktopKeyBar: View {
    let isMac: Bool
    let extendedKeys: Bool
    let clipboardRead: Bool
    @Binding var keyboard: Bool
    @Binding var modifiers: Set<String>
    let key: ([String]) -> Void
    let copyClipboard: () -> Void
    let paste: () -> Void
    let update: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { keyboard.toggle() } label: { AppIcon(keyboard ? .keyboardHide : .keyboard) }
                    .accessibilityLabel(keyboard ? "Hide keyboard" : "Type on desktop")
                keyButton("Esc", "Escape")
                keyButton("⇥", "Tab", label: "Tab")
                modifier("Ctrl", "Ctrl", label: "Control")
                modifier(isMac ? "⌥" : "Alt", "Alt", label: isMac ? "Option" : "Alt")
                modifier(isMac ? "⌘" : "Super", isMac ? "Meta" : "Super", label: isMac ? "Command" : "Super")
                modifier("⇧", "Shift", label: "Shift")
                keyButton("⌫", "Backspace", label: "Backspace")
                keyButton("↵", "Enter", label: "Return")
                ForEach([("←", "Left"), ("↑", "Up"), ("↓", "Down"), ("→", "Right")], id: \.1) { title, name in
                    keyButton(title, name)
                }
                AppMenu {
                    Section("Navigation") {
                        ForEach(["Home", "End", "PageUp", "PageDown", "Delete"], id: \.self) { name in
                            Button(keyLabel(name)) { key([name]) }
                        }
                    }
                    if extendedKeys {
                        AppMenu("Function keys") {
                            ForEach(1...24, id: \.self) { number in Button("F\(number)") { key(["F\(number)"]) } }
                        }
                        Section("More keys") {
                            ForEach(["CapsLock", "Insert", "PrintScreen", "Pause", "Menu", "NumLock", "ScrollLock"], id: \.self) { name in
                                Button(keyLabel(name)) { key([name]) }
                            }
                        }
                    } else {
                        Button("Update Mindwire for function keys", action: update)
                    }
                } label: { AppIcon(.keyboard) }.accessibilityLabel("More keys")
                AppMenu {
                    let command = isMac ? "Meta" : "Ctrl"
                    Button("Select all") { key([command, "a"]) }
                    Button("Copy") { key([command, "c"]) }
                    Button("Cut") { key([command, "x"]) }
                    Button("Paste on desktop") { key([command, "v"]) }
                    Button("Paste from iPhone", action: paste)
                    if clipboardRead { Button("Copy desktop clipboard to iPhone", action: copyClipboard) }
                    Button("Undo") { key([command, "z"]) }
                    Button("Redo") { key([command, "Shift", "z"]) }
                    Button("Find") { key([command, "f"]) }
                    Button("Save") { key([command, "s"]) }
                    Section("Browser and windows") {
                        Button("New window") { key([command, "n"]) }
                        Button("New tab") { key([command, "t"]) }
                        Button("Reopen closed tab") { key([command, "Shift", "t"]) }
                        Button("Reload") { key([command, "r"]) }
                        Button("Address bar") { key([command, "l"]) }
                    }
                    if isMac {
                        Section("Mac") {
                            Button("Spotlight") { key(["Meta", "Space"]) }
                            Button("Switch app") { key(["Meta", "Tab"]) }
                            Button("Switch window") { key(["Meta", "`"]) }
                            Button("Close window") { key(["Meta", "w"]) }
                            Button("Minimize window") { key(["Meta", "m"]) }
                            Button("Toggle app fullscreen") { key(["Ctrl", "Meta", "f"]) }
                            Button("Mission Control") { key(["Ctrl", "Up"]) }
                            Button("Screenshot controls") { key(["Meta", "Shift", "5"]) }
                            Button("Quit app") { key(["Meta", "q"]) }
                            Button("Force Quit…") { key(["Alt", "Meta", "Escape"]) }
                        }
                    }
                    Section("Terminal") {
                        Button("Interrupt (Control-C)") { key(["Ctrl", "c"]) }
                        Button("End input (Control-D)") { key(["Ctrl", "d"]) }
                    }
                } label: { AppIcon(.command) }.accessibilityLabel("Desktop shortcuts")
            }.buttonStyle(.borderless).font(.body).padding(.horizontal, 12).padding(.vertical, 6)
        }.frame(height: 48).background(.bar)
    }

    private func keyButton(_ title: String, _ name: String, label: String? = nil) -> some View {
        Button(title) { key([name]) }.frame(minWidth: 34, minHeight: 36).accessibilityLabel(label ?? name)
    }
    private func modifier(_ title: String, _ name: String, label: String) -> some View {
        Button(title) {
            if modifiers.contains(name) { modifiers.remove(name) } else { modifiers.insert(name) }
        }.frame(minWidth: 38, minHeight: 36)
            .background(modifiers.contains(name) ? Color.accentColor.opacity(0.18) : Color.clear, in: .capsule)
            .accessibilityLabel(label).accessibilityAddTraits(modifiers.contains(name) ? .isSelected : [])
            .accessibilityHint("Applies to the next key")
    }
    private func keyLabel(_ name: String) -> String {
        ["PageUp": "Page Up", "PageDown": "Page Down", "Delete": "Forward Delete", "CapsLock": "Caps Lock",
         "PrintScreen": "Print Screen", "NumLock": "Num Lock", "ScrollLock": "Scroll Lock"][name] ?? name
    }
}
