import os
import UserNotifications

/// Converts an agent push into an incoming communication notification. iOS presents the harness
/// avatar with the small Mindwire app badge. The relay must set aps.mutable-content to 1.
final class NotificationService: UNNotificationServiceExtension {
    private static let log = Logger(subsystem: "com.oblien.mindwire", category: "NotificationService")
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.lock()
        handler = contentHandler
        fallback = request.content
        work = Task { @MainActor [weak self] in
            do {
                let content = try await CommunicationNotification.content(from: request.content)
                Self.log.info("Prepared communication notification")
                self?.finish(content)
            } catch {
                let failure = error as NSError
                Self.log.error("Communication notification failed: \(failure.domain, privacy: .public) code=\(failure.code)")
                self?.finish(request.content)
            }
        }
        lock.unlock()
    }

    override func serviceExtensionTimeWillExpire() {
        let pending = lock.withLock { (work, fallback) }
        pending.0?.cancel()
        if let content = pending.1 { finish(content) }
    }

    private func finish(_ content: UNNotificationContent) {
        let completion = lock.withLock {
            let completion = handler
            handler = nil
            fallback = nil
            work = nil
            return completion
        }
        completion?(content)
    }
}
