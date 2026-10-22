import UIKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging
import CloudKit

/// Bridges a tapped notification to in-app navigation. Holds a weak `AppModel` (set at launch) and
/// routes the notification's `PushTarget` to it — stashing the target if the tap arrives before the
/// model is ready (e.g. cold launch from a notification).
@MainActor
final class PushRouter {
    static let shared = PushRouter()
    weak var app: AppModel?
    private var pending: (target: PushTarget, notificationID: String?)?

    func attach(_ app: AppModel) {
        self.app = app
        if let pending { app.open(pending.target, notificationID: pending.notificationID); self.pending = nil }
    }

    func route(_ target: PushTarget, notificationID: String? = nil) {
        if let app { app.open(target, notificationID: notificationID) }
        else { pending = (target, notificationID) }
    }
}

/// APNs → Firebase → Oblien registration, plus foreground presentation and tap navigation.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let widgetChanged = WidgetPushUpdates.record(data: PushPayload.data(from: userInfo))
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.containerIdentifier == CloudKitConnectionCloud.containerID,
              notification.subscriptionID == "mindwire-connection-sync." + CloudKitConnectionCloud.zoneName else {
            completionHandler(widgetChanged ? .newData : .noData)
            return
        }
        Task { @MainActor in
            let sync = Stores.shared.connectionSync
            guard sync.enabled else { completionHandler(.noData); return }
            await sync.syncNow()
            completionHandler(sync.error == nil ? .newData : .failed)
        }
    }
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        DesktopOrientations.supported(for: window)
    }
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
        return true
    }

    // APNs handed us the device token → give it to FCM so it can bridge APNs↔FCM for this install.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        Task { await BackendFactory.pushService().registerIfPossible() }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        APILog.note("push: APNs registration failed — \(error.localizedDescription.oneLine())")
    }

    // FCM token became available or rotated → (re)register this device with Oblien's registry.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else { return }
        Task {
            let ok = await BackendFactory.pushService().registerIfPossible()
            APILog.note("push: device registration \(ok ? "active in Mindwire" : "pending")")
        }
    }

    // Other chats still alert while the app is open, including chats of the same agent.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        WidgetPushUpdates.record(data: PushPayload.data(from: notification.request.content.userInfo))
        let target = PushTarget(payload: notification.request.content.userInfo)
        return await MainActor.run {
            PushPresentation.shared.options(for: target,
                appIsActive: UIApplication.shared.applicationState == .active,
                stores: PushRouter.shared.app?.stores)
        }
    }

    // Tap → open the thing the notification is about.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let target = PushTarget(payload: userInfo) else { return }
        await MainActor.run {
            PushRouter.shared.route(target, notificationID: response.notification.request.identifier)
        }
    }
}
