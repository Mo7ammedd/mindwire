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

/// Shared size preference for message text, markdown and desktop input. Desktop has a denser
/// reading scale; phone sizes and the user's Small/Medium/Large choice remain independent of it.
enum ChatTextSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    var points: CGFloat {
        #if targetEnvironment(macCatalyst)
        switch self {
        case .small: return 14
        case .medium: return 15
        case .large: return 17
        }
        #else
        switch self {
        case .small:  return 15
        case .medium: return 16.5
        case .large:  return 18.5
        }
        #endif
    }

    var label: String {
        switch self {
        case .small:  return t("settings.textSize.small")
        case .medium: return t("settings.textSize.medium")
        case .large:  return t("settings.textSize.large")
        }
    }
}
