import SwiftUI
import Observation

/// Backs AgentSettingsScreen: holds the editable name + schema-driven config bindings
/// (string/bool keyed by field key) and the save logic (rename + config persistence).
@MainActor
@Observable
final class AgentSettingsModel {
    let agentId: String

    var agent: Agent?
    var schema: DaemonSettingsSchema = .empty
    var name: String = ""

    /// Per-field string values (text / secret / select); keyed by `DaemonField.key`.
    var strings: [String: String] = [:]
    /// Per-field bool values (toggle); keyed by `DaemonField.key`.
    var bools: [String: Bool] = [:]
    var availableModels: [DaemonModelInfo] = []
    var loadingModels = false
    private var baseline: [String: String] = [:]
    var configurationLoaded = false

    private let stores: Stores

    init(agentId: String, stores: Stores) {
        self.agentId = agentId
        self.stores = stores
    }

    /// Load app-owned identity only. Adapter configuration is loaded from mindwired.
    func load() {
        guard let agent = stores.agents.get(agentId) else {
            self.agent = nil
            return
        }
        self.agent = agent
        self.name = agent.name
        self.schema = .empty
        configurationLoaded = false
        applyConfig([:])
    }

    private func applyConfig(_ config: [String: String]) {
        var strings: [String: String] = [:]
        var bools: [String: Bool] = [:]
        for section in schema.sections {
            for field in section.fields {
                let value = config[field.key]
                switch field.type {
                case .toggle:
                    bools[field.key] = value.map { $0 == "true" } ?? (field.default == "true")
                case .text, .secret, .select, .multiselect:
                    strings[field.key] = value ?? (field.default ?? "")
                }
            }
        }
        self.strings = strings
        self.bools = bools
    }

    func stringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { self.strings[key] ?? "" },
            set: { self.strings[key] = $0 }
        )
    }

    func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { self.bools[key] ?? false },
            set: { self.bools[key] = $0 }
        )
    }

    /// Adopt the daemon's schema and native config snapshot together.
    func adopt(schema: DaemonSettingsSchema, config: [String: String]) {
        self.schema = schema
        applyConfig(config)
        baseline = nonSecretConfig()
        configurationLoaded = true
    }

    var configBinding: Binding<[String: String]> {
        Binding(get: { self.nonSecretConfig() }, set: { self.applyConfig($0) })
    }

    func changedConfig() -> [String: String] { AgentSettingsDraft.changes(nonSecretConfig(), from: baseline) }

    func loadModels(using session: DaemonSession, force: Bool = false) async {
        guard !loadingModels, session.capabilities?.models == true else { return }
        loadingModels = true
        defer { loadingModels = false }
        if let models = try? await session.models(force: force) { availableModels = models }
    }

    var modelName: String {
        let field = schema.sections.flatMap(\.fields).first(where: { $0.canon == "model" })
        let selected = field.flatMap { strings[$0.key] } ?? ""
        let model = AgentSettingsDraft.model(in: schema, values: strings, models: availableModels)
        return model?.label ?? field?.options?.first(where: { $0.value == selected && !selected.isEmpty })?.label
            ?? (selected.isEmpty ? t("agentSettings.default") : selected)
    }

    var modelAcceptsAudio: Bool {
        AgentSettingsDraft.model(in: schema, values: strings, models: availableModels)?
            .inputModalities?.contains("audio") == true
    }

    /// Resolve the saved effort (or the model's native default) using the same choices as the form.
    var reasoningLabel: String? {
        guard let field = schema.sections.flatMap(\.fields).first(where: {
            $0.canon == "reasoningEffort" && $0.type != .secret && $0.isVisible(values: strings)
        }) else { return nil }
        let model = AgentSettingsDraft.model(in: schema, values: strings, models: availableModels)
        guard model?.reasoning != false else { return nil }
        let selected = strings[field.key] ?? ""
        let effort = selected.isEmpty ? model?.defaultReasoningEffort ?? "" : selected
        guard !effort.isEmpty else { return t("agentSettings.default") }
        return AgentSettingsDraft.choices(for: field, schema: schema, values: strings, models: availableModels)
            .first(where: { $0.value == effort })?.label ?? effort
    }

    var modelSummary: String {
        let effort = schema.sections.flatMap(\.fields).first(where: { $0.canon == "reasoningEffort" })
            .flatMap { strings[$0.key] } ?? ""
        return effort.isEmpty ? modelName : "\(modelName) · \(effort)"
    }

    /// Non-secret settings to push to the daemon via `setConfig`; empty values clear overrides. Secrets
    /// are owned by the auth flow and never sent here (the daemon drops them anyway).
    func nonSecretConfig() -> [String: String] {
        var out: [String: String] = [:]
        for section in schema.sections {
            for field in section.fields {
                switch field.type {
                case .secret:
                    continue
                case .toggle:
                    out[field.key] = (bools[field.key] ?? false) ? "true" : "false"
                case .text, .select, .multiselect:
                    let value = strings[field.key] ?? ""
                    out[field.key] = value // an empty value clears a previously selected override
                }
            }
        }
        return out
    }

    /// Persist only the app-owned display name. Configuration belongs to mindwired.
    @discardableResult
    func save() async throws -> Bool {
        guard agent != nil else { return false }
        try await stores.workspaceData.renameAgent(agentId, name: name)
        return true
    }

    var hasConfig: Bool { !schema.sections.isEmpty }
}
