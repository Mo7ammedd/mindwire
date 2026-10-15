import XCTest
@testable import Mindwire

@MainActor
final class NotificationSignInReminderTests: XCTestCase {
    private let owner = UUID()
    func testAnotherWindowCannotDismissOrConsumeTheActiveReminder() throws {
        let (defaults, reminder) = try fixture()
        XCTAssertTrue(reminder.claim(owner: owner, signedOut: true, active: true, canPresent: true))
        let other = UUID()
        reminder.finish(.notNow, owner: other)
        XCTAssertTrue(reminder.isPresenting)
        XCTAssertFalse(reminder.claim(owner: other, signedOut: true, active: true, canPresent: true))
        reminder.finish(.later, owner: owner)
        let later = NotificationSignInReminder(defaults: defaults,
            now: { Date().addingTimeInterval(8 * 86_400) })
        XCTAssertTrue(later.claim(owner: other, signedOut: true, active: true, canPresent: true),
                      "The unrelated dismissal must not replace Remind me later with Not now")
    }

    func testFreshInstallCanExplainNotificationsOnceAcrossMultipleWindows() throws {
        let (_, reminder) = try fixture()
        XCTAssertFalse(reminder.claim(owner: owner, signedOut: false, active: true, canPresent: true))
        XCTAssertFalse(reminder.claim(owner: owner, signedOut: true, active: false, canPresent: true))
        XCTAssertFalse(reminder.claim(owner: owner, signedOut: true, active: true, canPresent: false), "Never interrupt another sheet")
        XCTAssertTrue(reminder.claim(owner: owner, signedOut: true, active: true, canPresent: true))
        XCTAssertFalse(reminder.claim(owner: owner, signedOut: true, active: true, canPresent: true))
        reminder.finish(.notNow, owner: owner)
    }

    func testNotNowPersistsWithoutMutingAnyWorkspaces() throws {
        let (defaults, reminder) = try fixture()
        XCTAssertTrue(reminder.claim(owner: owner, signedOut: true, active: true, canPresent: true))
        reminder.finish(.notNow, owner: owner)
        let relaunched = NotificationSignInReminder(defaults: defaults,
            now: { Date().addingTimeInterval(365 * 86_400) })
        XCTAssertFalse(relaunched.claim(owner: owner, signedOut: true, active: true, canPresent: true))
        XCTAssertNil(defaults.object(forKey: StorageKey.agents))
        XCTAssertNil(defaults.object(forKey: StorageKey.workspaces))
    }

    func testRemindMeLaterWaitsAWeekIncludingAcrossRelaunches() throws {
        let (defaults, _) = try fixture()
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let reminder = NotificationSignInReminder(defaults: defaults, now: { date })
        XCTAssertTrue(reminder.claim(owner: owner, signedOut: true, active: true, canPresent: true))
        reminder.finish(.later, owner: owner)
        date = date.addingTimeInterval(6 * 86_400)
        let next = NotificationSignInReminder(defaults: defaults, now: { date })
        XCTAssertFalse(next.claim(owner: owner, signedOut: true, active: true, canPresent: true))
        date = date.addingTimeInterval(86_400 + 1)
        XCTAssertTrue(next.claim(owner: owner, signedOut: true, active: true, canPresent: true))
        next.finish(.later, owner: owner)
    }

    func testInterruptedSignInDoesNotImmediatelyShowTheSheetAgain() throws {
        let (_, reminder) = try fixture()
        XCTAssertTrue(reminder.claim(owner: owner, signedOut: true, active: true, canPresent: true))
        reminder.finish(.signIn, owner: owner)
        reminder.finish(.notNow, owner: owner) // the dismissed introductory sheet's callback
        XCTAssertFalse(reminder.claim(owner: owner, signedOut: true, active: true, canPresent: true))
    }

    private func fixture() throws -> (UserDefaults, NotificationSignInReminder) {
        let suite = "notification-reminder-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, NotificationSignInReminder(defaults: defaults))
    }
}
