import Foundation

/// App-wide constants ported from the RN client + shared core.
enum AppConstants {
    static let daemonPort = 8790
    static let mindwireServicesBase = "https://console.mindwire.sh"
    // Mindwire is versioned and distributed through GitHub Releases. The app resolves the latest
    // stable tag, compares it with /healthz, and downloads the matching Linux asset when needed.
    static let mindwireRepository = "oblien/mindwire"
    static let mindwireReleaseAPI = "https://api.github.com/repos/oblien/mindwire/releases/latest"
    static let appVersion = "1.0.0"
}

/// `UserDefaults` (plain JSON) keys shared with other Mindwire clients.
enum StorageKey {
    static let agents = "mindwire:agents"
    static let connections = "mindwire:connections"
    static let workspaces = "mindwire:workspaces"
    static let cloudWorkspaceCache = "mindwire:cloud-workspace-cache:v1"
    /// Read once when upgrading from builds that called this domain object a sandbox.
    static let legacySandboxes = "mindwire:sandboxes"
    static let projects = "mindwire:projects"
    static let chats = "mindwire:chats"
    static let bots = "mindwire:bots"
    static let github = "mindwire:github"
    static let themeMode = "mindwire:theme"
    static let locale = "mindwire:locale"
    static let chatTextSize = "mindwire:chatTextSize"
    static let releaseCatalog = "mindwire:releaseCatalog"
    static let automaticServiceUpdates = "mindwire:automaticServiceUpdates"
    static func catalog(_ version: String) -> String { "mindwire:catalog:\(version)" }
    static func schema(_ agentType: String) -> String { "mindwire:schema:\(agentType)" }
    static func agentConfig(_ id: String) -> String { "mindwire:agentcfg:\(id)" }
    static func agentConfigSecrets(_ id: String) -> String { "mindwire:agentcfg:\(id):secrets" }
}

/// Keychain item keys (only `[A-Za-z0-9._-]` allowed — dots, never colons).
enum KeychainKey {
    static let sessionToken = "mindwire.oblien.session"
    static let deviceId = "mindwire.device.id"   // stable per-install id for push registration
    static func agentConfigSecret(_ id: String, _ field: String) -> String { "mindwire.agentcfg.\(id).\(field)" }
    static func serverSecret(_ id: String) -> String { "mindwire.server.\(id).secret" }
    static func serverKey(_ id: String) -> String { "mindwire.server.\(id).key" }
    static func githubToken(_ id: String) -> String { "mindwire.github.\(id).token" }
    static func githubSshKey(_ id: String) -> String { "mindwire.github.\(id).sshkey" }
    static func runtimeToken(_ workspaceId: String) -> String { "mindwire.runtime.\(sanitized(workspaceId)).token" }
    /// Sanitize an arbitrary caller key to the keychain-safe charset.
    static func sanitized(_ raw: String) -> String {
        String(raw.map { ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "_" || $0 == "-" ? $0 : "_" })
    }
}
