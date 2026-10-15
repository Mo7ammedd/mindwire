import XCTest
import SwiftUI
import UserNotifications
@testable import Mindwire

@MainActor
final class PushPresentationTests: XCTestCase {
    private let normal: UNNotificationPresentationOptions = [.banner, .sound, .badge]

    private func stores() throws -> Stores {
        let suite = "push-presentation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    func testVisibleChatIsSilentButOtherChatsOfTheSameAgentStillAlert() {
        let presentation = PushPresentation(), owner = UUID()
        presentation.setVisibleChat("chat-x", owner: owner)
        let payloads: [[AnyHashable: Any]] = [
            ["target_type": "chat", "target_id": "chat-x", "agent": "codex"],
            ["data": ["chatId": "chat-x", "agent": "codex"]],
            ["data": #"{"target_type":"chat","target_id":"chat-x"}"#]
        ]
        for payload in payloads {
            XCTAssertEqual(presentation.options(for: PushTarget(payload: payload), appIsActive: true, stores: nil), [])
        }
        let other = PushTarget(payload: ["chatId": "chat-y", "agent": "codex"])
        XCTAssertEqual(presentation.options(for: other, appIsActive: true, stores: nil), normal)
        XCTAssertEqual(presentation.options(for: .agent("codex"), appIsActive: true, stores: nil), normal)
        XCTAssertEqual(presentation.options(for: nil, appIsActive: true, stores: nil), normal)
    }

    func testLeavingBackgroundingAndReplacingAChatRestoreCorrectPresentation() {
        let presentation = PushPresentation(), old = UUID(), replacement = UUID()
        presentation.setVisibleChat("chat", owner: old)
        XCTAssertEqual(presentation.options(for: .chat("chat"), appIsActive: false, stores: nil), normal)
        presentation.setVisibleChat("chat", owner: replacement)
        presentation.setVisibleChat(nil, owner: old)
        XCTAssertEqual(presentation.options(for: .chat("chat"), appIsActive: true, stores: nil), [])
        presentation.setVisibleChat(nil, owner: replacement)
        XCTAssertEqual(presentation.options(for: .chat("chat"), appIsActive: true, stores: nil), normal)
    }

    func testConfirmedMutesFilterInFlightPushesByProfileAndClearExplicitly() throws {
        let stores = try stores(), presentation = PushPresentation()
        var first = Agent(id: "profile-a", name: "Codex", agentType: .codex, createdAt: "now", notificationsMuted: true)
        let second = Agent(id: "profile-b", name: "Other Codex", agentType: .codex, createdAt: "now")
        var chat = Chat(id: "chat-x", agentId: first.id, projectId: "project", title: "Chat", createdAt: "now", notificationsMuted: false)
        stores.agents.replaceAll([first, second])
        stores.chats.replaceAll([chat, Chat(id: "chat-y", agentId: second.id, projectId: "project", title: "Other", createdAt: "now")])
        XCTAssertEqual(presentation.options(for: .chat(chat.id), appIsActive: true, stores: stores), [])
        XCTAssertEqual(presentation.options(for: .chat("chat-y"), appIsActive: true, stores: stores), normal)
        XCTAssertEqual(presentation.options(for: .agent(first.id), appIsActive: true, stores: stores), [])
        first.notificationsMuted = false
        stores.agents.save(first)
        XCTAssertEqual(presentation.options(for: .chat(chat.id), appIsActive: true, stores: stores), normal)
        chat.notificationsMuted = true
        stores.chats.save(chat)
        let reopened = Stores(defaults: stores.defaults)
        XCTAssertEqual(presentation.options(for: .chat(chat.id), appIsActive: true, stores: reopened), [])
        XCTAssertEqual(reopened.agents.get(first.id)?.notificationsMuted, false)
    }

    func testActualNavigationTabAndSceneLifecycleOnlySuppressesTheVisibleChat() async throws {
        let state = PresentationNavigationFixture()
        let app = AppModel(stores: try stores())
        app.selectedTab = .agents
        let view = PresentationNavigationView(state: state).environment(app)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        func silent(_ id: String) -> Bool {
            PushPresentation.shared.options(for: .chat(id), appIsActive: true, stores: nil).isEmpty
        }
        state.path = ["visible-fixture-x"]
        try await eventually { silent("visible-fixture-x") }
        XCTAssertFalse(silent("visible-fixture-y"))
        state.path.append("visible-fixture-y")
        try await eventually { silent("visible-fixture-y") && !silent("visible-fixture-x") }
        state.path.removeLast()
        try await eventually { silent("visible-fixture-x") && !silent("visible-fixture-y") }
        app.selectedTab = .projects
        try await eventually { !silent("visible-fixture-x") }
        app.selectedTab = .agents
        try await eventually { silent("visible-fixture-x") }
        state.phase = .background
        try await eventually { !silent("visible-fixture-x") }
        state.phase = .active
        try await eventually { silent("visible-fixture-x") }
        state.path = []
        try await eventually { !silent("visible-fixture-x") }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Notification presentation did not follow the view lifecycle")
    }
}

@MainActor @Observable
private final class PresentationNavigationFixture {
    var path: [String] = []
    var phase = ScenePhase.active
}

private struct PresentationNavigationView: View {
    @Bindable var state: PresentationNavigationFixture
    var body: some View {
        NavigationStack(path: $state.path) {
            Text("Chats").navigationDestination(for: String.self) { id in
                Text(id).visibleChatForNotifications(id)
            }
        }
        .environment(\.scenePhase, state.phase)
    }
}
