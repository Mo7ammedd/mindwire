import Foundation

/// Lightweight scalar preferences (UserDefaults).
enum AppPrefs {
    private static let defaults = UserDefaults.standard

    /// Cosmetic toggle (the app is forced dark via Info.plist for v1).
    static var darkMode: Bool {
        get { defaults.object(forKey: StorageKey.themeMode) as? Bool ?? true }
        set { defaults.set(newValue, forKey: StorageKey.themeMode) }
    }

    static var locale: String {
        get { defaults.string(forKey: StorageKey.locale) ?? "en" }
        set { defaults.set(newValue, forKey: StorageKey.locale) }
    }
}

/// User-selectable chat text size (drives the markdown body + user bubble). Medium reads like a
/// comfortable message size — deliberately NOT the shrunken 15pt experiment, and not oversized.
/// Block spacing in the renderer scales off this, so the whole layout breathes at every size.
enum ChatTextSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    var points: CGFloat {
        switch self {
        case .small:  return 15
        case .medium: return 16.5
        case .large:  return 18.5
        }
    }

    var label: String {
        switch self {
        case .small:  return t("settings.textSize.small")
        case .medium: return t("settings.textSize.medium")
        case .large:  return t("settings.textSize.large")
        }
    }
}
