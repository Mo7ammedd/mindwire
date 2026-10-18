import SwiftUI
import XCTest
import UIKit
@testable import Mindwire

@MainActor
final class AssistantBotTests: XCTestCase {
    private func stores() -> Stores {
        let suite = "assistant-bots-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func bot(_ id: String = "writer", revision: Int64 = 1, agentId: String = "agent", projectId: String = "project") -> AssistantBot {
        AssistantBot(id: id, workspaceId: "registry", agentId: agentId, projectId: projectId, name: "Writing Partner",
            purpose: "Write clearly", instructions: "Ask about the audience", memory: "Short paragraphs",
            knowledge: [.init(id: "style", title: "Style guide", content: "Use active voice.")],
            isMaster: false, archived: false, createdAt: "2026-10-01T00:00:00Z", revision: revision)
    }

    func testBotSnapshotsDeltasAndRelaunchKeepKnowledgeAndChatMembership() throws {
        let stores = stores()
        let workspace = Workspace(id: "computer", name: "Computer", runtime: .server(serverId: "server"), createdAt: "2026-10-01T00:00:00Z")
        let data = WorkspaceDataRepository(stores: stores, resolveWorkspace: { _ in workspace })
        var snapshot = WorkspaceMetadata(version: 1, workspaceId: "registry", revision: 1, full: true,
            agents: [.init(id: "agent", name: "AI", agentType: .codex, workspaceId: "registry", createdAt: workspace.createdAt, revision: 1)],
            projects: [.init(id: "project", name: "General", workspaceId: "registry", path: "/general", createdAt: workspace.createdAt, revision: 1)],
            chats: [.init(id: "chat", agentId: "agent", projectId: "project", title: "First draft", createdAt: workspace.createdAt, revision: 1, botId: "writer")], deleted: [], bots: [bot()])
        try data.apply(snapshot, workspaceId: workspace.id)
        XCTAssertEqual(stores.bots.get("writer")?.workspaceId, workspace.id)
        XCTAssertEqual(stores.chats.get("chat")?.botId, "writer")
        var updated = bot(revision: 2)
        updated.instructions = "Ask about the audience, then write concise prose."
        updated.icon = "blue-spark"
        snapshot = WorkspaceMetadata(version: 1, workspaceId: "registry", revision: 2, full: false,
            agents: [], projects: [], chats: [], deleted: [], bots: [updated])
        try data.apply(snapshot, workspaceId: workspace.id)
        let reopened = Stores(defaults: stores.defaults)
        XCTAssertEqual(reopened.bots.get("writer")?.instructions, updated.instructions)
        XCTAssertEqual(reopened.bots.get("writer")?.memory, "Short paragraphs")
        XCTAssertEqual(reopened.bots.get("writer")?.icon, "blue-spark")
        XCTAssertEqual(reopened.bots.get("writer")?.knowledge.first?.content, "Use active voice.")
        XCTAssertEqual(reopened.chats.get("chat")?.botId, "writer")
    }

    func testIconCatalogAndMessageColorsStayReadable() {
        var icons = Set<String>()
        func luminance(_ components: [Double]) -> Double {
            let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let ink = luminance([0.13, 0.15, 0.16])
        for color in BotColor.allCases {
            let rgb = color.rgb
            let fill = luminance([Double((rgb >> 16) & 255) / 255, Double((rgb >> 8) & 255) / 255, Double(rgb & 255) / 255])
            XCTAssertGreaterThanOrEqual((fill + 0.05) / (ink + 0.05), 4.5, color.rawValue)
            for character in BotCharacter.allCases {
                let icon = AssistantBotIcon(color: color, character: character)
                icons.insert(icon.id)
                XCTAssertEqual(AssistantBotIcon.resolve(botId: "any-bot", icon: icon.id), icon)
            }
        }
        XCTAssertEqual(icons.count, 56)
        XCTAssertEqual(AssistantBotIcon.resolve(botId: "writer", icon: nil), AssistantBotIcon.resolve(botId: "writer", icon: ""))
    }

    func testBotColorUpdatesCrossRecycledTranscriptCells() async throws {
        let stores = stores(), app = AppModel(stores: stores)
        let host = UIHostingController(rootView: BotColorProbeHost(color: .blue, stores: stores, app: app))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func labels(_ view: UIView) -> [String] {
            (view as? UILabel).flatMap(\.text).map { [$0] } ?? []
                + view.subviews.flatMap(labels)
        }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        XCTAssertTrue(labels(host.view).contains("blue:general:true"))
        host.rootView = BotColorProbeHost(color: .lilac, stores: stores, app: app)
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        XCTAssertTrue(labels(host.view).contains("lilac:general:true"), "An unchanged message must adopt the bot's new color")
    }

    func testBotNavigationKeepsSeparateDraftsAndRestoresAnEmptyBot() {
        let stores = stores()
        stores.experience.mode = .general
        var first = bot(); first.workspaceId = "computer"; stores.bots.save(first)
        var second = bot("study"); second.workspaceId = "computer"; stores.bots.save(second)
        stores.chats.save(Chat(id: "writing-chat", agentId: "agent", projectId: "project", title: "Article", createdAt: "2026-10-01T00:00:00Z", botId: first.id))
        stores.chatDrafts.draft(for: "writing-chat").text = "Unfinished article"
        let app = AppModel(stores: stores)
        app.openBot(first.id)
        XCTAssertEqual(app.assistantChatID, "writing-chat")
        app.openBot(second.id)
        XCTAssertEqual(app.assistantBotID, second.id)
        XCTAssertNil(app.assistantChatID)
        let restored = AppModel(stores: stores)
        restored.restoreNavigation(app.navigationSnapshot)
        XCTAssertEqual(restored.assistantBotID, second.id)
        XCTAssertNil(restored.assistantChatID)
        restored.openBot(first.id)
        XCTAssertEqual(stores.chatDrafts.draft(for: "writing-chat").text, "Unfinished article")
    }

    func testCollapsedBotGroupsSurvivePreferenceReload() {
        let stores = stores()
        stores.experience.collapsedBotIDs = ["writer", "study"]
        let reopened = Stores(defaults: stores.defaults)
        XCTAssertEqual(reopened.experience.collapsedBotIDs, ["writer", "study"])
    }

    func testNativeMCPAndCommandToolResultsDecodeTheirSavedBotReference() throws {
        let result = #"{"mindwireBot":{"operation":"created","botId":"writer","name":"Writing Partner","revision":2}}"#
        let wrapped = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": result]]])
        XCTAssertEqual(AssistantBotToolResult.parse(String(decoding: wrapped, as: UTF8.self))?.botId, "writer")
        XCTAssertEqual(AssistantBotToolResult.parse(result)?.revision, 2)
        XCTAssertNil(AssistantBotToolResult.parse("I created a bot named Writer."))
        XCTAssertNil(AssistantBotToolResult.parse(#"{"mindwireBot":{"name":"Missing saved ID"}}"#))
    }

    func testRemovingAParentDropsOnlyItsCachedBotProfiles() {
        let stores = stores()
        stores.bots.save(bot())
        let other = bot("other", agentId: "another-agent", projectId: "another-project")
        stores.bots.save(other)
        stores.forgetProject("project")
        XCTAssertNil(stores.bots.get("writer"))
        XCTAssertNotNil(stores.bots.get("other"))
        stores.deleteAgent("another-agent")
        XCTAssertTrue(stores.bots.list().isEmpty)
    }
}

private struct BotColorProbeRow: Identifiable, Equatable { let id = 0 }

private struct BotColorProbeHost: View {
    let color: BotColor
    let stores: Stores
    let app: AppModel
    var body: some View {
        ChatTranscriptScrollView(rows: [BotColorProbeRow()], isRunning: false) { _ in BotColorProbe() }
            .environment(\.stores, stores).environment(app)
            .environment(\.chatBotColor, color).environment(\.appExperienceMode, .general)
    }
}

private struct BotColorProbe: UIViewRepresentable {
    @Environment(\.chatBotColor) private var color
    @Environment(\.appExperienceMode) private var mode
    @Environment(AppModel.self) private var app: AppModel?
    func makeUIView(context: Context) -> UILabel { UILabel() }
    func updateUIView(_ label: UILabel, context: Context) { label.text = "\(color?.rawValue ?? "none"):\(mode.rawValue):\(app != nil)" }
}
