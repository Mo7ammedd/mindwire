import SwiftUI

/// The shared palette for bot identities and soft application surfaces.
enum BotColor: String, CaseIterable, Identifiable {
    case mint, amber, lilac, blue, peach, rose, olive, cyan, coral, periwinkle
    var id: String { rawValue }
    var title: String { t("assistant.icons.color.\(rawValue)") }
    var rgb: UInt32 {
        switch self {
        case .mint: 0x78BAA9
        case .amber: 0xEEB457
        case .lilac: 0x9878ED
        case .blue: 0x6797F0
        case .peach: 0xEB9257
        case .rose: 0xE39BBC
        case .olive: 0xB8C76D
        case .cyan: 0x6BC4D0
        case .coral: 0xED817B
        case .periwinkle: 0x9297E8
        }
    }
    var fill: Color {
        Color(red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    static let brand: BotColor = .peach
    static let ink = Color(red: 0.13, green: 0.15, blue: 0.16)
}

private struct ChatBotColorKey: EnvironmentKey {
    static let defaultValue: BotColor? = nil
}

extension EnvironmentValues {
    /// Derived from the same identity as chat bubbles; no separate activity theme to sync.
    var chatAccent: Color { (chatBotColor ?? .brand).fill }

    var chatBotColor: BotColor? {
        get { self[ChatBotColorKey.self] }
        set { self[ChatBotColorKey.self] = newValue }
    }
}
