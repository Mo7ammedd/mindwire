import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class AgentOptionsTests: XCTestCase {
    private func stores() throws -> Stores {
        let name = "agent-options-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return Stores(defaults: defaults)
    }

    func testNativeModelMetadataDrivesBothHarnessesWithoutAnEffortAllowlistInTheApp() throws {
        let models = try JSONDecoder().decode([DaemonModelInfo].self, from: Data(#"[{"id":"gpt-6-astra","label":"GPT 6 Astra","default":true,"reasoningEfforts":[{"value":"high","label":"High"},{"value":"max","label":"Max","help":"Maximum reasoning"}],"defaultReasoningEffort":"high"},{"id":"other-model","label":"Other model","reasoningEfforts":[{"value":"low","label":"Low"}]}]"#.utf8))
        for key in ["reasoning-effort", "effort"] {
            let modelField = DaemonField(key: "model", label: "Model", type: .text, canon: "model")
            let effort = DaemonField(key: key, label: "Reasoning effort", type: .text, canon: "reasoningEffort")
            let schema = DaemonSettingsSchema(sections: [.init(title: "Model & reasoning", fields: [modelField, effort])])
            var draft = ["model": "gpt-6-astra", key: "max"]
            XCTAssertEqual(AgentSettingsDraft.choices(for: effort, schema: schema, values: draft, models: models).map(\.value), ["high", "max"])
            AgentSettingsDraft.selectModel("other-model", field: modelField, schema: schema, models: models, values: &draft)
            XCTAssertEqual(draft[key], "", "Changing model resets an incompatible reasoning choice")
            XCTAssertEqual(AgentSettingsDraft.choices(for: effort, schema: schema, values: draft, models: models).map(\.value), ["low"])
            AgentSettingsDraft.selectModel("private-deployment", field: modelField, schema: schema, models: models, values: &draft)
            XCTAssertTrue(AgentSettingsDraft.choices(for: effort, schema: schema, values: draft, models: models).isEmpty,
                          "Unknown deployments retain manual entry instead of borrowing another model's limits")
        }
    }

    func testSettingsDraftOnlySendsActualChangesAndNeverCredentials() throws {
        let store = try stores()
        let settings = AgentSettingsModel(agentId: "agent", stores: store)
        let schema = DaemonSettingsSchema(sections: [.init(title: "Settings", fields: [
            .init(key: "model", label: "Model", type: .text, canon: "model"),
            .init(key: "effort", label: "Reasoning effort", type: .text, canon: "reasoningEffort"),
            .init(key: "summary", label: "Summary", type: .select, canon: "reasoningSummary", default: "auto"),
            .init(key: "apiKey", label: "Credential", type: .secret)
        ])])
        settings.adopt(schema: schema, config: ["model": "workspace-model", "effort": "high", "apiKey": "fixture-secret"])
        XCTAssertTrue(settings.changedConfig().isEmpty)
        settings.strings["effort"] = "max"
        XCTAssertEqual(settings.changedConfig(), ["effort": "max"])
        XCTAssertNil(settings.nonSecretConfig()["apiKey"])
        XCTAssertEqual(settings.modelSummary, "workspace-model · max")
        settings.strings["effort"] = ""
        XCTAssertEqual(settings.changedConfig(), ["effort": ""], "Clearing an override must reach the workspace")
    }

    func testSettingsChangesReachDaemonAndReadBackAfterRefresh() async throws {
        let channel = OptionsChannel()
        let id = UUID().uuidString
        let session = DaemonSession(agentId: id, transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: id) }
        await session.load()
        let settings = AgentSettingsModel(agentId: id, stores: try stores())
        settings.adopt(schema: session.schema, config: try await session.config())
        await settings.loadModels(using: session)
        XCTAssertEqual(settings.availableModels.first?.reasoningEfforts?.last?.value, "max")
        settings.strings["model"] = "gpt-6-astra"
        settings.strings["reasoning-effort"] = "max"
        try await session.saveConfig(settings.changedConfig())
        let saved = try await session.config()
        XCTAssertEqual(saved["model"], "gpt-6-astra")
        XCTAssertEqual(saved["reasoning-effort"], "max")
        XCTAssertEqual(saved["request-max-retries"], "4", "An unrelated native setting must not be cleared")
        let patches = await channel.patches
        XCTAssertEqual(patches, [["model": "gpt-6-astra", "reasoning-effort": "max"]])
    }

    func testSharedSettingsRenderLabeledModelAndEffortControls() async throws {
        let channel = OptionsChannel()
        let id = UUID().uuidString
        let session = DaemonSession(agentId: id, transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: id) }
        await session.load()
        let models = try await session.models()
        let view = UIHostingController(rootView: NavigationStack {
            Form {
                AgentSettingsFields(schema: session.schema,
                    values: .constant(["model": "gpt-6-astra", "reasoning-effort": "max", "reasoning-summary": "auto"]), models: models)
            }.navigationTitle("Model settings")
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = view
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(250))
        let image = ChatFeedSnapshot.image(view)
        let text = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(text.contains("GPT 6 Astra"), text)
        XCTAssertTrue(text.contains("Reasoning effort"), text)
        XCTAssertTrue(text.contains("Max"), text)
        XCTAssertTrue(text.contains("Reasoning summary"), text)
        let attachment = XCTAttachment(image: image)
        attachment.name = "mindwire-model-reasoning-settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mindwire-model-reasoning-settings.png")
        try image.pngData()?.write(to: path)
        print("MODEL_SETTINGS_SNAPSHOT_PATH=\(path.path)")
    }

    func testUnchangedAuthenticationRefreshDoesNotRefetchModelList() async throws {
        let channel = OptionsChannel()
        let id = UUID().uuidString
        let session = DaemonSession(agentId: id, transport: ExecDaemonTransport(channel: channel, agentType: "codex"))
        defer { DaemonWorkCoordinator.shared.forget(workspaceId: id) }
        await session.load()
        _ = try await session.models()
        await session.refresh()
        _ = try await session.models()
        var requests = await channel.modelRequests
        XCTAssertEqual(requests, 1)
        _ = try await session.models(force: true)
        requests = await channel.modelRequests
        XCTAssertEqual(requests, 2, "An explicit refresh bypasses the model cache")
        await channel.upgradeCLI()
        await session.refresh()
        _ = try await session.models()
        requests = await channel.modelRequests
        XCTAssertEqual(requests, 3, "A harness update invalidates its model capabilities immediately")
    }
}

private actor OptionsChannel: DaemonChannel {
    nonisolated let label = "agent-options-fixture"
    private var config = ["model": "previous-model", "reasoning-effort": "high", "request-max-retries": "4"]
    private(set) var patches: [[String: String]] = []
    private(set) var modelRequests = 0
    private var cliVersion = "0.155.1"
    func upgradeCLI() { cliVersion = "0.156.0" }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        switch (method, path) {
        case ("GET", "/setup?agent=codex"):
            return (200, #"{"ok":true,"running":false,"started":false,"steps":[]}"#)
        case ("GET", "/agent?agent=codex"):
            return (200, #"{"version":"0.1.17","agentType":"codex","name":"Codex","installedVersion":"0.155.1","configured":true,"authStatus":{"configured":true},"capabilities":{"models":true,"authLogout":true},"authMethods":[{"id":"login","label":"Continue with ChatGPT","interactive":true}],"schema":{"sections":[{"title":"Model & reasoning","fields":[{"key":"model","canon":"model","type":"text","label":"Model"},{"key":"reasoning-effort","canon":"reasoningEffort","type":"text","label":"Reasoning effort"},{"key":"reasoning-summary","canon":"reasoningSummary","type":"select","label":"Reasoning summary","options":[{"value":"auto","label":"Auto"},{"value":"none","label":"None"}]}]}]}}"#.replacingOccurrences(of: "0.155.1", with: cliVersion))
        case ("GET", "/models?agent=codex"):
            modelRequests += 1
            return (200, #"[{"id":"gpt-6-astra","label":"GPT 6 Astra","reasoningEfforts":[{"value":"high","label":"High"},{"value":"max","label":"Max"}],"defaultReasoningEffort":"high"}]"#)
        case ("GET", "/config?agent=codex"):
            return (200, String(decoding: try JSONEncoder().encode(config), as: UTF8.self))
        case ("PUT", "/config?agent=codex"):
            let patch = try JSONDecoder().decode([String: String].self, from: jsonBody ?? Data())
            patches.append(patch)
            config.merge(patch) { _, new in new }
            return (204, "")
        default: throw URLError(.unsupportedURL)
        }
    }
}
