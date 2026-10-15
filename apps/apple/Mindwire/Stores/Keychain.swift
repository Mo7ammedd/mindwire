import Foundation
import Security

/// Thin keychain wrapper. Keys must be in `[A-Za-z0-9._-]`. All ops swallow failures.
enum Keychain {
    private static let service = "com.oblien.mindwire"
    private static let protectionLock = NSLock()
    private static var computerCredentialsProtected = false

    // A paired phone is a device identity. Restoring a backup onto another phone
    // must not silently clone that approval. Keep background reconnect available
    // after the first unlock without allowing computer credentials to migrate.
    private static func accessibility(for key: String) -> CFString {
        key.hasPrefix("computer.") || key.hasPrefix("mindwire.sync.device.") ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            : kSecAttrAccessibleAfterFirstUnlock
    }

    private static func prepareComputerCredentials() -> Bool {
        protectionLock.withLock {
            if computerCredentialsProtected { return true }
            computerCredentialsProtected = migrateComputerCredentials()
            return computerCredentialsProtected
        }
    }

    /// Protect every saved copy on first Keychain use, including old pending
    /// receipts that ordinary reconnect never reads. Enumerate attributes only;
    /// private key data is neither read nor replaced during migration.
    @discardableResult
    static func migrateComputerCredentials() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return true }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return false }
        for item in items {
            guard let key = item[kSecAttrAccount as String] as? String, key.hasPrefix("computer."),
                  item[kSecAttrAccessible as String] as? String != accessibility(for: key) as String else { continue }
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            let attributes = [kSecAttrAccessible as String: accessibility(for: key)]
            let updated = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
            // Concurrent local removal is already safe. Other errors remain
            // retryable; don't authorize a computer until every copy is bound.
            guard updated == errSecSuccess || updated == errSecItemNotFound else { return false }
        }
        return true
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let protectionReady = prepareComputerCredentials()
        guard protectionReady || !key.hasPrefix("computer.") else { return false }
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Update in place: deleting first would lose a working token whenever
        // the replacement write fails (for example while Keychain is locked).
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility(for: key),
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query
        add.merge(attributes) { _, new in new }
        let inserted = SecItemAdd(add as CFDictionary, nil)
        // Another writer may have inserted the same key between update and add.
        if inserted == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        return inserted == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let protectionReady = prepareComputerCredentials()
        guard protectionReady || !key.hasPrefix("computer.") else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data else { return nil }
        if key.hasPrefix("computer."),
           item[kSecAttrAccessible as String] as? String != accessibility(for: key) as String {
            // Also protect a legacy item restored after the initial migration.
            // A failed change must not silently leave this identity migratable.
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            let attributes = [kSecAttrAccessible as String: accessibility(for: key)]
            guard SecItemUpdate(match as CFDictionary, attributes as CFDictionary) == errSecSuccess else { return nil }
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Oblien session token (anonymous or attached to an OAuth identity).
enum SessionToken {
    static func get() -> String? { Keychain.get(KeychainKey.sessionToken) }
    static func set(_ token: String) { Keychain.set(token, for: KeychainKey.sessionToken) }
    static func clear() { Keychain.delete(KeychainKey.sessionToken) }
}
