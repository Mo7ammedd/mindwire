import Foundation

/// Server-type identity (title/subtitle i18n keys) for the add-server pickers.
struct ModeVisual: Hashable {
    let titleKey: String
    let subtitleKey: String
}

enum Modes {
    static let visuals: [ConnectionType: ModeVisual] = [
        .local: .init(titleKey: "mode.local.title", subtitleKey: "mode.local.subtitle"),
        .ssh: .init(titleKey: "mode.ssh.title", subtitleKey: "mode.ssh.subtitle"),
        .vps: .init(titleKey: "mode.vps.title", subtitleKey: "mode.vps.subtitle"),
    ]
    /// Personal computers use pairing; SSH and VPS share the existing server form.
    static let order: [ConnectionType] = [.local, .ssh]
}
