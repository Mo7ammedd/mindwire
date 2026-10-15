import SwiftUI

/// Follow the first strong character, just as a native text editor does. Numbers,
/// punctuation and emoji do not make an Arabic paragraph left-to-right.
enum ChatTextDirection {
    static func direction(for text: String) -> LayoutDirection? {
        for scalar in text.unicodeScalars {
            if scalar.value == 0x200F || scalar.value == 0x061C { return .rightToLeft }
            if scalar.value == 0x200E { return .leftToRight }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                let rtl = (0x0590...0x08FF).contains(scalar.value)
                    || (0xFB1D...0xFDFF).contains(scalar.value)
                    || (0xFE70...0xFEFF).contains(scalar.value)
                    || (0x1E800...0x1EEFF).contains(scalar.value)
                return rtl ? .rightToLeft : .leftToRight
            default: continue
            }
        }
        return nil
    }
}

private struct NaturalChatDirection: ViewModifier {
    let text: String
    let fillWidth: Bool
    @Environment(\.layoutDirection) private var inherited

    func body(content: Content) -> some View {
        Group {
            if fillWidth { content.frame(maxWidth: .infinity, alignment: .leading) }
            else { content }
        }
        .multilineTextAlignment(.leading)
        .environment(\.layoutDirection, ChatTextDirection.direction(for: text) ?? inherited)
    }
}

extension View {
    func naturalChatDirection(_ text: String, fillWidth: Bool = false) -> some View {
        modifier(NaturalChatDirection(text: text, fillWidth: fillWidth))
    }
}
