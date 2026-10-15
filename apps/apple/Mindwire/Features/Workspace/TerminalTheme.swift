import SwiftTerm
import UIKit

/// Terminal text size — small/medium/large, persisted via the terminal settings menu.
enum TerminalFontSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var points: CGFloat {
        switch self {
        case .small:  return 12
        case .medium: return 13
        case .large:  return 15
        }
    }
    static func points(for id: String) -> CGFloat {
        (TerminalFontSize(rawValue: id) ?? .medium).points
    }
}

/// A terminal color theme — window chrome colors plus the 16-entry ANSI palette SwiftTerm
/// renders. Applied to a `TerminalView` via `installColors` + the native color properties.
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: UIColor
    let foreground: UIColor
    let caret: UIColor
    let ansi: [SwiftTerm.Color]

    static func == (lhs: TerminalTheme, rhs: TerminalTheme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Hex helpers

private func ui(_ hex: UInt32) -> UIColor {
    UIColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

private func tc(_ hex: UInt32) -> SwiftTerm.Color {
    SwiftTerm.Color(
        red: UInt16((hex >> 16) & 0xff) * 257,
        green: UInt16((hex >> 8) & 0xff) * 257,
        blue: UInt16(hex & 0xff) * 257
    )
}

// MARK: - Presets

extension TerminalTheme {
    static let oblienDark = TerminalTheme(
        id: "oblien-dark", name: "Oblien Dark",
        background: ui(0x0B0B0F), foreground: ui(0xE6E6E6), caret: ui(0xE25D3E),
        ansi: [
            tc(0x1C1C1E), tc(0xFF5C57), tc(0x5AF78E), tc(0xF3F99D),
            tc(0x57C7FF), tc(0xFF6AC1), tc(0x9AEDFE), tc(0xE6E6E6),
            tc(0x6E6E73), tc(0xFF5C57), tc(0x5AF78E), tc(0xF3F99D),
            tc(0x57C7FF), tc(0xFF6AC1), tc(0x9AEDFE), tc(0xFFFFFF),
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        background: ui(0x282A36), foreground: ui(0xF8F8F2), caret: ui(0xF8F8F2),
        ansi: [
            tc(0x21222C), tc(0xFF5555), tc(0x50FA7B), tc(0xF1FA8C),
            tc(0xBD93F9), tc(0xFF79C6), tc(0x8BE9FD), tc(0xF8F8F2),
            tc(0x6272A4), tc(0xFF6E6E), tc(0x69FF94), tc(0xFFFFA5),
            tc(0xD6ACFF), tc(0xFF92DF), tc(0xA4FFFF), tc(0xFFFFFF),
        ]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark",
        background: ui(0x002B36), foreground: ui(0x839496), caret: ui(0x93A1A1),
        ansi: [
            tc(0x073642), tc(0xDC322F), tc(0x859900), tc(0xB58900),
            tc(0x268BD2), tc(0xD33682), tc(0x2AA198), tc(0xEEE8D5),
            tc(0x002B36), tc(0xCB4B16), tc(0x586E75), tc(0x657B83),
            tc(0x839496), tc(0x6C71C4), tc(0x93A1A1), tc(0xFDF6E3),
        ]
    )

    static let snazzyLight = TerminalTheme(
        id: "light", name: "Light",
        background: ui(0xFBF7F1), foreground: ui(0x2B2B2B), caret: ui(0xE25D3E),
        ansi: [
            tc(0x2B2B2B), tc(0xD7401F), tc(0x36802D), tc(0x9A7400),
            tc(0x2D6FB8), tc(0xA3308E), tc(0x1F8C8C), tc(0xE6E6E6),
            tc(0x808080), tc(0xD7401F), tc(0x36802D), tc(0x9A7400),
            tc(0x2D6FB8), tc(0xA3308E), tc(0x1F8C8C), tc(0xFFFFFF),
        ]
    )

    static let all: [TerminalTheme] = [oblienDark, dracula, solarizedDark, snazzyLight]
    static let `default` = oblienDark

    static func with(id: String) -> TerminalTheme { all.first { $0.id == id } ?? .default }
}
