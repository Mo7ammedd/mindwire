import Foundation

/// Legacy local config cleanup for app versions that mirrored daemon-owned settings on-device.
/// New code never writes here; mindwired's native config and credential stores are authoritative.
enum AgentConfigStore {
    private static let defaults = UserDefaults.standard

    static func clear(_ agentId: String) {
        for key in secretKeys(agentId) {
            Keychain.delete(KeychainKey.agentConfigSecret(agentId, key))
        }
        defaults.removeObject(forKey: StorageKey.agentConfig(agentId))
        defaults.removeObject(forKey: StorageKey.agentConfigSecrets(agentId))
    }

    private static func secretKeys(_ agentId: String) -> [String] {
        guard let data = defaults.data(forKey: StorageKey.agentConfigSecrets(agentId)),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return keys
    }
}
