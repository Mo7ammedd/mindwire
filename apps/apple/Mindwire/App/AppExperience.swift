import SwiftUI
import Observation

enum AppExperienceMode: String, CaseIterable, Identifiable {
    case general, developer
    var id: String { rawValue }
    var title: String { t("experience.\(rawValue)") }
    var detail: String { t("experience.\(rawValue).detail") }
    var icon: AppIconName { self == .general ? .message : .terminal }
}

/// Presentation preferences only. Credentials, conversations and running work keep their
/// existing owners. Persist changes to these small identifiers, never a second transcript.
@MainActor @Observable
final class AppExperience {
    private let defaults: UserDefaults
    var mode: AppExperienceMode? {
        didSet { defaults.set(mode?.rawValue, forKey: Self.modeKey) }
    }
    var assistantAgentID: String? {
        didSet { defaults.set(assistantAgentID, forKey: "mindwire.assistant.agent") }
    }
    var pendingWorkspaceID: String? {
        didSet { defaults.set(pendingWorkspaceID, forKey: "mindwire.assistant.setup.workspace") }
    }
    var pendingAgentID: String? {
        didSet { defaults.set(pendingAgentID, forKey: "mindwire.assistant.setup.agent") }
    }
    private(set) var projectIDs: [String: String]
    var collapsedBotIDs: Set<String> {
        didSet { defaults.set(Array(collapsedBotIDs).sorted(), forKey: "mindwire.assistant.collapsedBots") }
    }
    private static let modeKey = "mindwire.experience.mode"

    init(defaults: UserDefaults, hasExistingData: Bool) {
        self.defaults = defaults
        let savedMode = defaults.string(forKey: Self.modeKey).flatMap(AppExperienceMode.init(rawValue:))
        #if targetEnvironment(macCatalyst)
        // Desktop begins with the local personal assistant. Keep an existing explicit
        // mode preference; switching remains available in the shared Settings screen.
        mode = savedMode ?? .general
        #else
        mode = savedMode ?? (hasExistingData ? .developer : nil)
        // Upgrades retain the familiar interface. Fresh installations choose explicitly.
        if savedMode == nil, hasExistingData {
            defaults.set(AppExperienceMode.developer.rawValue, forKey: Self.modeKey)
        }
        #endif
        assistantAgentID = defaults.string(forKey: "mindwire.assistant.agent")
        pendingWorkspaceID = defaults.string(forKey: "mindwire.assistant.setup.workspace")
        pendingAgentID = defaults.string(forKey: "mindwire.assistant.setup.agent")
        projectIDs = defaults.dictionary(forKey: "mindwire.assistant.projects") as? [String: String] ?? [:]
        collapsedBotIDs = Set(defaults.stringArray(forKey: "mindwire.assistant.collapsedBots") ?? [])
    }

    func use(agent: Agent, project: Project) {
        guard agent.workspaceId == project.workspaceId else { return }
        projectIDs[project.workspaceId] = project.id
        defaults.set(projectIDs, forKey: "mindwire.assistant.projects")
        assistantAgentID = agent.id
        pendingWorkspaceID = nil
        pendingAgentID = nil
    }
}

private struct AppExperienceModeKey: EnvironmentKey {
    static let defaultValue = AppExperienceMode.developer
}

extension EnvironmentValues {
    var appExperienceMode: AppExperienceMode {
        get { self[AppExperienceModeKey.self] }
        set { self[AppExperienceModeKey.self] = newValue }
    }
}
