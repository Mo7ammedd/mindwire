import XCTest
import FirebaseCore
import SwiftUI
import UIKit
import UserNotifications
@testable import Mindwire

/// Opt-in check on a signed-in physical iPhone. The daemon's TestPushDeliveryLive reads the
/// temporary, device-pinned send credential from Caches/mindwire-push-check.json and sends three
/// labelled checks through its real notifier. No FCM device token leaves Oblien's device registry.
@MainActor
final class PushDeliveryLiveTests: XCTestCase {
    func testRegistrationAndDeliveryOnPhysicalDevice() async throws {
        guard ProcessInfo.processInfo.environment["MINDWIRE_LIVE_PUSH"] == "1" else {
            throw XCTSkip("Set MINDWIRE_LIVE_PUSH=1 on a signed-in physical iPhone.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("This check requires actual APNs delivery on an iPhone.")
        #else
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        XCTAssertEqual(FirebaseApp.app()?.options.bundleID, Bundle.main.bundleIdentifier)
        await MindwireAuth.shared.refresh()
        guard MindwireAuth.shared.authenticated else {
            XCTFail("Sign in to Oblien in this Mindwire install before the push check.")
            return
        }
        let push = BackendFactory.pushService()
        await push.start()
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            XCTFail("Notifications are not allowed for this Mindwire bundle in iOS Settings.")
            return
        }
        let deadline = Date().addingTimeInterval(30)
        var registered = false
        repeat {
            registered = await push.registerIfPossible()
            if registered { break }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        XCTAssertTrue(registered, "APNs/FCM token must register with Oblien under the new bundle ID.")
        guard registered else { return }
        let device = try await NotificationsAPI().status(deviceId: DeviceID.current())
        XCTAssertTrue(device.isActive)
        let deviceRowID = try XCTUnwrap(device.id)
        print("Push check: signed-in account, permission allowed, device registry active.")

        let remote = ProcessInfo.processInfo.environment["MINDWIRE_LIVE_PUSH_REMOTE"] == "1"
        let stores = Stores.shared
        let candidates = stores.agents.list().filter { agent in
            guard let id = agent.workspaceId, let workspace = WorkspaceRepository.shared.get(id) else { return false }
            if !remote { return workspace.isCloud }
            return workspace.runtime.serverId.flatMap { stores.connections.get($0)?.pairedComputer } != nil
                && workspace.runtime.sandbox == nil
        }
        let agent = try XCTUnwrap(candidates.first, "Connect an agent on the workspace being checked.")
        let workspaceID = try XCTUnwrap(agent.workspaceId)
        let workspace = try XCTUnwrap(WorkspaceRepository.shared.get(workspaceID))
        let scope = try XCTUnwrap(WorkspaceNotificationScope(workspaceID: workspaceID, runtime: workspace.runtime))
        if remote {
            // Exercise the real app preparation path over the saved, authenticated SSH pairing.
            // It must configure the already-running daemon without another pairing or a restart.
            let session = DaemonManager.shared.session(for: agent.id, stores: stores)
            try await session.prepare()
            await session.reconcileNotifications(force: true)
            let computer = try XCTUnwrap(workspace.runtime.serverId.flatMap { stores.connections.get($0)?.pairedComputer })
            let api = DaemonHTTP(channel: ComputerDaemonChannel(computer: computer, stores: stores), agentType: agent.agentType.rawValue)
            let config: DaemonNotifyConfig = try await api.decode("GET", "/notify/config", quiet: true)
            XCTAssertTrue(config.configured)
            XCTAssertEqual(config.format, "push")
            XCTAssertEqual(config.hasToken, true)
            XCTAssertEqual(config.channel, workspaceID)
            XCTAssertEqual(config.url, WorkspaceNotify.sendURL)
            print("Push check: paired computer configured through its existing SSH connection.")
        }
        let marker = "notification-check-" + UUID().uuidString
        let chatID = Stores.shared.chats.list().first?.id ?? marker
        let received = expectation(description: "Completion, approval, and error notifications received over APNs")
        received.expectedFulfillmentCount = 3
        let previous = center.delegate
        let probe = PushReceiptProbe(marker: marker, received: received)
        center.delegate = probe
        defer { center.delegate = previous }
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                for notification in await center.deliveredNotifications() {
                    probe.record(notification.request.content, source: "notification-center")
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poller.cancel() }
        let minted = try await NotificationsAPI().createSendToken(
            workspaceID: scope.cloudWorkspaceID,
            tag: "mindwire-push-check-\(DeviceID.current())", name: "Mindwire notification check",
            metadata: ["device_id": String(deviceRowID), "channel": workspaceID], expiresInDays: 1)
        let handoff = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mindwire-push-check.json")
        defer { try? FileManager.default.removeItem(at: handoff) }
        do {
            let token = try XCTUnwrap(minted.token)
            let data = try JSONSerialization.data(withJSONObject: [
                "url": WorkspaceNotify.sendURL, "token": token, "channel": workspaceID,
                "chatId": chatID, "runPrefix": marker,
            ])
            try data.write(to: handoff, options: [.atomic, .completeFileProtection])
            print("Push check: ready for daemon delivery fixture.")
            await fulfillment(of: [received], timeout: 90)
            XCTAssertEqual(probe.contents.count, 3)
            var conditions = Set<String>()
            for content in probe.contents.values {
                let metadata = PushPayload.data(from: content.userInfo)
                XCTAssertEqual(PushTarget(payload: content.userInfo), .chat(chatID))
                XCTAssertTrue(["codex", "claude-code"].contains(metadata["agent"] as? String ?? ""))
                conditions.insert(metadata["condition"] as? String ?? "")
                let aps = content.userInfo["aps"] as? [String: Any]
                XCTAssertEqual(aps?["mutable-content"] as? Int, 1)
                print("Push check: condition=\(metadata["condition"] ?? ""), mutable-content=\(aps?["mutable-content"] ?? "absent"), title=\(content.title)")
                let archive = try NSKeyedArchiver.archivedData(withRootObject: content, requiringSecureCoding: true)
                // iOS keeps the server's title in foreground callbacks. The native sender/avatar
                // lives in the archived communication context instead. Inspect this diagnostic
                // artifact only in the opt-in device test; app code uses public Intents APIs.
                let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any])
                let classes = (plist["$objects"] as? [[String: Any]])?.compactMap { $0["$classname"] as? String }
                    ?? (plist["$objects"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["$classname"] as? String }
                XCTAssertTrue(classes.contains("_UNNotificationCommunicationContext"), "Missing native communication presentation")
                XCTAssertTrue(classes.contains("_UNNotificationContact"), "Missing harness sender")
                let attachment = XCTAttachment(data: archive, uniformTypeIdentifier: "com.apple.property-list")
                attachment.name = "notification-content-\(metadata["condition"] ?? "unknown")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertEqual(conditions, ["finished", "waiting_approval", "error"])
        } catch {
            try? await NotificationsAPI().deleteSendToken(id: minted.id)
            throw error
        }
        try await NotificationsAPI().deleteSendToken(id: minted.id)
        print("Push check: temporary send credential removed.")
        try await captureWorkspaces(stores: stores)
        #endif
    }

    private func captureWorkspaces(stores: Stores) async throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow))
        var presenting = try XCTUnwrap(window.rootViewController)
        while let top = presenting.presentedViewController { presenting = top }
        let navigation = AppModel(stores: stores)
        navigation.selectedTab = .workspaces
        let screen = UIHostingController(rootView: MainScene().environment(navigation).environment(\.stores, stores))
        screen.modalPresentationStyle = .fullScreen
        presenting.present(screen, animated: false)
        defer { screen.dismiss(animated: false) }
        try await Task.sleep(for: .seconds(1))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "physical-iphone-workspace-status"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class PushReceiptProbe: NSObject, UNUserNotificationCenterDelegate {
    let marker: String
    let received: XCTestExpectation
    @MainActor var contents: [String: UNNotificationContent] = [:]
    init(marker: String, received: XCTestExpectation) { self.marker = marker; self.received = received }
    @MainActor
    func record(_ content: UNNotificationContent, source: String) {
        guard let run = PushPayload.data(from: content.userInfo)["runId"] as? String,
              run.hasPrefix(marker), contents[run] == nil else { return }
        contents[run] = content
        print("Push check: received via \(source), sender=\(content.title)")
        received.fulfill()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await record(notification.request.content, source: "foreground")
        return [.banner, .list, .sound]
    }
}
