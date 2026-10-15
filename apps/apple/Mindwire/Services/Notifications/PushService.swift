import Foundation
import UIKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging
import Observation

protocol FCMTokenProvider: Sendable {
    func currentToken() async -> String?
    func deleteToken() async throws
}

struct FirebaseFCMTokenProvider: FCMTokenProvider {
    func currentToken() async -> String? {
        // A cached FCM token must be associated with this install's current APNs token,
        // particularly after changing the bundle ID or restoring a device.
        let ready = await MainActor.run {
            FirebaseApp.app() != nil && Messaging.messaging().apnsToken != nil
        }
        guard ready else { return nil }
        return try? await Messaging.messaging().token()
    }

    func deleteToken() async throws {
        guard FirebaseApp.app() != nil else { return }
        try await Messaging.messaging().deleteToken()
    }
}

@MainActor
protocol PushAuthorization {
    func status() async -> UNAuthorizationStatus
    func request() async throws -> Bool
    func registerForRemoteNotifications()
}

struct SystemPushAuthorization: PushAuthorization {
    func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func request() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

@MainActor
protocol PushService {
    /// Reconcile permission, APNs, and the signed-in account's device registration.
    func start() async
    @discardableResult func registerIfPossible() async -> Bool
    func isRegistered() async -> Bool
    func setActive(_ active: Bool)
    /// Finish any registration and remove the device before the account session is cleared.
    func unregister() async
}

enum PushRegistrationState: Equatable {
    case checking, signInRequired, permissionRequired, permissionDenied
    case waitingForToken, registering, ready
    case failed(String)

    var needsRetry: Bool {
        switch self {
        case .waitingForToken, .failed: true
        default: false
        }
    }
}

enum DeviceID {
    static func current() -> String {
        if let existing = Keychain.get(KeychainKey.deviceId), !existing.isEmpty { return existing }
        let id = UUID().uuidString
        Keychain.set(id, for: KeychainKey.deviceId)
        return id
    }
}

@MainActor
@Observable
final class LivePushService: PushService {
    static let shared = LivePushService(network: .shared,
        refreshAccount: { await OblienAuth.shared.refresh() },
        didRegister: { await DaemonManager.shared.reconcileNotifications(force: true) })

    private(set) var state: PushRegistrationState = .checking
    private(set) var authorizationStatus: UNAuthorizationStatus?

    private let api: PushDeviceRegistry
    private let tokens: FCMTokenProvider
    private let authorization: PushAuthorization
    private let accountID: () -> Int?
    private let deviceID: () -> String
    private var registration: (id: UUID, account: Int, token: String, task: Task<Bool, Never>)?
    private var registered: (account: Int, token: String)?
    private var unregistering = false
    private var suspended = false
    @ObservationIgnored private var startup: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var retry: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var observation: ComputerNetworkMonitor.Observation?
    private let refreshAccount: () async -> Void
    private let didRegister: () async -> Void
    private let retryDelay: (Int) -> Duration
    private var active = false
    private var retryAttempt = 0
    private var networkState: ComputerNetworkMonitor.State?

    init(api: PushDeviceRegistry = NotificationsAPI(),
         tokens: FCMTokenProvider = FirebaseFCMTokenProvider(),
         authorization: PushAuthorization? = nil,
         accountID: (() -> Int?)? = nil,
         deviceID: @escaping () -> String = DeviceID.current,
         network: ComputerNetworkMonitor? = nil,
         refreshAccount: @escaping () async -> Void = {},
         didRegister: @escaping () async -> Void = {},
         retryDelay: @escaping (Int) -> Duration = { .seconds([5, 15, 60, 300][min($0, 3)]) }) {
        self.api = api
        self.tokens = tokens
        self.authorization = authorization ?? SystemPushAuthorization()
        self.accountID = accountID ?? { OblienAuth.shared.authenticated ? OblienAuth.shared.user?.id : nil }
        self.deviceID = deviceID
        self.refreshAccount = refreshAccount
        self.didRegister = didRegister
        self.retryDelay = retryDelay
        networkState = network?.state
        observation = network?.observe { [weak self] state in
            Task { @MainActor in self?.networkChanged(state) }
        }
    }

    func start() async {
        if let startup { await startup.task.value; return }
        let id = UUID()
        let task = Task {
            // Login/logout may finish while a request is in flight. Settle that request,
            // then reconcile the current identity before releasing the shared operation.
            repeat {
                let account = self.accountID()
                await self.reconcileDevice()
                if account == self.accountID() || self.unregistering { return }
            } while !Task.isCancelled
        }
        startup = (id, task)
        await task.value
        if startup?.id == id { startup = nil }
    }

    private func reconcileDevice() async {
        guard !unregistering else { return }
        authorizationStatus = await authorization.status()
        guard accountID() != nil else { state = .signInRequired; cancelRetry(); return }
        suspended = false
        var status = authorizationStatus ?? .notDetermined
        if status == .notDetermined {
            _ = try? await authorization.request()
            status = await authorization.status()
            authorizationStatus = status
        }
        guard Self.allowed(status) else {
            state = status == .notDetermined ? .permissionRequired : .permissionDenied
            cancelRetry()
            return
        }
        authorization.registerForRemoteNotifications()
        // Returning installs may have both tokens and receive no FCM refresh callback.
        // The APNs delegate retries when a first-time install's token arrives later.
        await registerIfPossible()
    }

    @discardableResult
    func registerIfPossible() async -> Bool {
        defer { scheduleRetryIfNeeded() }
        guard !suspended, !unregistering else { return false }
        guard let account = accountID() else { state = .signInRequired; return false }
        let status = await authorization.status()
        authorizationStatus = status
        guard Self.allowed(status) else {
            state = status == .notDetermined ? .permissionRequired : .permissionDenied
            return false
        }
        guard let token = await tokens.currentToken(), !token.isEmpty else {
            state = .waitingForToken
            return false
        }
        guard accountID() == account, !suspended else { return false }

        if let pending = registration {
            let result = await pending.task.value
            if registration?.id == pending.id { registration = nil }
            if pending.account == account && pending.token == token {
                return result && accountID() == account && !suspended
            }
            // A token rotation during an earlier request must not be lost to deduplication.
            return await registerIfPossible()
        }
        let id = UUID()
        let task = Task { await self.register(token: token, account: account) }
        registration = (id, account, token, task)
        let result = await task.value
        if registration?.id == id { registration = nil }
        return result
    }

    private func register(token: String, account: Int, canRefreshToken: Bool = true) async -> Bool {
        guard accountID() == account, !suspended else { return false }
        let info = ["model": UIDevice.current.model, "os": UIDevice.current.systemVersion,
                    "app_version": AppConstants.appVersion,
                    "bundle_id": Bundle.main.bundleIdentifier ?? ""]
        do {
            if registered?.account == account, registered?.token == token {
                if try await api.status(deviceId: deviceID()).isActive {
                    return markRegistered(token: token, account: account)
                }
            }
            state = .registering
            let device = try await api.registerDevice(deviceId: deviceID(), fcmToken: token,
                                                       platform: "ios", deviceInfo: info)
            guard device.isActive else {
                state = .failed("The notification service has not activated this device yet.")
                return false
            }
            return markRegistered(token: token, account: account)
        } catch {
            guard accountID() == account, !suspended else { return false }
            if canRefreshToken, case APIError.http(400, let detail) = error,
               detail?.contains("invalid_device_token") == true {
                try? await tokens.deleteToken()
                if let fresh = await tokens.currentToken(), !fresh.isEmpty, fresh != token {
                    return await register(token: fresh, account: account, canRefreshToken: false)
                }
            }
            if case APIError.http(401, _) = error { await refreshAccount() }
            state = accountID() == nil ? .signInRequired : .failed(error.localizedDescription.oneLine())
            APILog.note("push: device registration failed — \(error.localizedDescription.oneLine())")
            return false // launch, foreground, login, and token callbacks all retry
        }
    }

    private func markRegistered(token: String, account: Int) -> Bool {
        guard accountID() == account, !suspended else { return false }
        let changed = state != .ready || registered?.account != account || registered?.token != token
        registered = (account, token)
        state = .ready
        retryAttempt = 0
        cancelRetry()
        if changed { Task { await didRegister() } }
        return true
    }

    func setActive(_ active: Bool) {
        self.active = active
        if active { scheduleRetryIfNeeded() }
        else { cancelRetry() }
    }

    private func networkChanged(_ next: ComputerNetworkMonitor.State) {
        let changed = networkState != next
        networkState = next
        guard next.reachable else { cancelRetry(); return }
        guard changed, active, !suspended, accountID() != nil, state.needsRetry else { return }
        cancelRetry()
        retryAttempt = 0
        Task { await start() }
    }

    private func scheduleRetryIfNeeded() {
        guard active, !suspended, !unregistering, accountID() != nil,
              networkState?.reachable != false, state.needsRetry else { cancelRetry(); return }
        guard retry == nil else { return }
        let id = UUID(), delay = retryDelay(retryAttempt)
        retryAttempt = min(retryAttempt + 1, 3)
        let task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.retry?.id == id else { return }
            self.retry = nil
            await self.start()
        }
        retry = (id, task)
    }

    private func cancelRetry() {
        retry?.task.cancel()
        retry = nil
    }

    func isRegistered() async -> Bool {
        guard accountID() != nil, !suspended, Self.allowed(await authorization.status()) else { return false }
        return (try? await api.status(deviceId: deviceID()))?.isActive ?? false
    }

    func unregister() async {
        suspended = true
        state = .signInRequired
        cancelRetry()
        registered = nil
        unregistering = true
        defer { unregistering = false }
        if let pending = registration { _ = await pending.task.value }
        registration = nil
        do {
            if let id = try await api.status(deviceId: deviceID()).id {
                try await api.removeDevice(id: id)
            }
        } catch {
            APILog.note("push: device removal failed — \(error.localizedDescription.oneLine())")
        }
        // Invalidate the transport token too, including when registry removal was offline.
        try? await tokens.deleteToken()
    }

    private static func allowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }
}
