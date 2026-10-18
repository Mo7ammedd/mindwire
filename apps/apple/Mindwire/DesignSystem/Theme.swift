import SwiftUI

/// Semantic surfaces with a warm orange accent. Text accents deepen
/// in light mode; pastel fills retain charcoal text in either appearance.
enum Palette {
    // MARK: Brand (the single accent)
    static let accent = Color("Accent")
    static let accentSoft = Color("AccentSoft")
    static let onAccent = Color("OnAccent")

    /// Editors and terminal themes choose their own appearance independently of the window.
    static func accentColor(for style: UIUserInterfaceStyle) -> UIColor {
        (UIColor(named: "Accent") ?? .systemOrange)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    // MARK: Backgrounds — let grouped system fills show; never a hard black screen.
    static let bg = Color(.systemGroupedBackground)
    static let bgElevated = Color(.systemBackground)
    static let surface = Color(.secondarySystemGroupedBackground)
    static let surfaceAlt = Color(.tertiarySystemGroupedBackground)

    // MARK: Separators
    static let border = Color(.separator)
    static let borderStrong = Color(.opaqueSeparator)

    // MARK: Text
    static let text = Color.primary
    static let textDim = Color.secondary
    static let textFaint = Color(.tertiaryLabel)

    // MARK: Semantic (system colors — tasteful, not the old lime green)
    static let success = Color.green
    static let danger = Color.red
    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(BotColor.amber.fill)
            : UIColor(red: 0.50, green: 0.34, blue: 0.08, alpha: 1)
    })

    /// Per-agent tint — brand accent for Claude, neutral label for the rest.
    static func agentColor(_ id: AgentID) -> Color { id == .claudeCode ? accent : .primary }

    /// Restrained status tint: active work leans on the brand/blue, green only for
    /// "ready", red for error, neutral grey for idle/archived. No more all-green statuses.
    static func statusTint(_ status: AgentStatus) -> Color {
        switch status {
        case .ready:           return .green
        case .running:         return accent
        case .provisioning:    return .blue
        case .awaitingInput:   return warning
        case .error:           return .red
        case .idle, .archived: return .secondary
        }
    }
}

/// 4-pt spacing grid.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner radii.
enum Radius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let pill: CGFloat = 999
}
