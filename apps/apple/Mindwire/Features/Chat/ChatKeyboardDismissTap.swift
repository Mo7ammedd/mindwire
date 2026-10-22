import SwiftUI
import UIKit

/// Ends native editing without consuming button taps or scroll gestures.
/// Containers that include search fields opt into ignoring taps inside editable controls.
struct ChatKeyboardDismissTap: UIGestureRecognizerRepresentable {
    var avoidsEditableControls = false
    var enabled = true
    let onDismiss: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let tap = UITapGestureRecognizer()
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        tap.isEnabled = enabled
        context.coordinator.avoidsEditableControls = avoidsEditableControls
        return tap
    }

    func updateUIGestureRecognizer(_ recognizer: UITapGestureRecognizer, context: Context) {
        recognizer.isEnabled = enabled
        context.coordinator.avoidsEditableControls = avoidsEditableControls
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        let window = recognizer.view?.window
        ChatKeyboardDismissal.dismiss(in: window, at: recognizer.location(in: window), onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var avoidsEditableControls = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard avoidsEditableControls else { return true }
            var view = touch.view
            while let current = view {
                if current is UITextField || (current as? UITextView)?.isEditable == true { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

/// Text selection can own first responder too. Dismissing the composer must not end
/// a rendered message's selection on the first or second tap of a word.
@MainActor
enum ChatKeyboardDismissal {
    static func dismiss(in window: UIWindow?, at point: CGPoint? = nil, onDismiss: () -> Void) {
        guard let window, let responder = firstResponder(in: window) else { return }
        if let text = responder as? UITextView, !text.isEditable {
            // Leave taps on the selected text to UIKit. A tap outside ends selection,
            // allowing the message to display any output received while selecting.
            if let point, let hit = window.hitTest(point, with: nil), hit !== text, !hit.isDescendant(of: text) {
                text.resignFirstResponder()
            }
            return
        }
        guard responder is UITextField || (responder as? UITextView)?.isEditable == true else { return }
        onDismiss()
        responder.resignFirstResponder()
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let responder = firstResponder(in: child) { return responder }
        }
        return nil
    }
}
