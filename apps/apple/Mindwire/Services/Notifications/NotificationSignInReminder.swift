import Foundation

/// Device-local education, not a notification preference. Dismissing it never mutes an agent.
/// Shared by all windows so first launch cannot stack multiple sign-in sheets.
@MainActor
final class NotificationSignInReminder {
    enum Choice { case notNow, later, signIn }
    private let defaults: UserDefaults
    private let now: () -> Date
    private var presentationOwner: UUID?
    var isPresenting: Bool { presentationOwner != nil }
    private static let dismissedKey = "mindwire.notifications.signInHint.dismissed"
    private static let nextDateKey = "mindwire.notifications.signInHint.nextDate"

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func claim(owner: UUID, signedOut: Bool, active: Bool, canPresent: Bool) -> Bool {
        guard signedOut, active, canPresent, !isPresenting,
              !defaults.bool(forKey: Self.dismissedKey),
              defaults.double(forKey: Self.nextDateKey) <= now().timeIntervalSince1970 else { return false }
        presentationOwner = owner
        // If the app is killed with the sheet open, do not show it on every restart.
        defaults.set(now().addingTimeInterval(7 * 86_400).timeIntervalSince1970, forKey: Self.nextDateKey)
        return true
    }

    func finish(_ choice: Choice, owner: UUID) {
        guard presentationOwner == owner else { return }
        presentationOwner = nil
        if choice == .notNow { defaults.set(true, forKey: Self.dismissedKey) }
        else { defaults.set(now().addingTimeInterval(7 * 86_400).timeIntervalSince1970, forKey: Self.nextDateKey) }
    }
}
