import XCTest
import Security
@testable import Mindwire

final class ComputerCredentialTests: XCTestCase {
    func testComputerIdentityAndAcknowledgementsStayOnThisPhone() throws {
        for suffix in ["key", "token", "pending-pairing"] {
            let key = "computer.\(UUID().uuidString).\(suffix)"
            defer { Keychain.delete(key) }
            XCTAssertTrue(Keychain.set("initial-fixture", for: key))
            XCTAssertEqual(Keychain.get(key), "initial-fixture")
            XCTAssertEqual(try storedAccessibility(key), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            XCTAssertTrue(Keychain.set("updated-fixture", for: key))
            XCTAssertEqual(Keychain.get(key), "updated-fixture")
            XCTAssertEqual(try storedAccessibility(key), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        }
    }

    func testExistingPairingMigratesWithoutLosingItsPrivateKey() throws {
        let key = "computer.\(UUID().uuidString).key"
        defer { Keychain.delete(key) }
        var attributes = query(key)
        attributes[kSecValueData as String] = Data("retained-key-fixture".utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(try storedAccessibility(key), kSecAttrAccessibleAfterFirstUnlock as String)

        XCTAssertEqual(Keychain.get(key), "retained-key-fixture")
        XCTAssertEqual(try storedAccessibility(key), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(Keychain.get(key), "retained-key-fixture")
        XCTAssertTrue(Keychain.delete(key))
        XCTAssertNil(Keychain.get(key))
    }

    func testMigrationAlsoProtectsUnreadCopiesInPendingPairingReceipts() throws {
        let prefix = "computer.\(UUID().uuidString)"
        let keys = [prefix + ".key", prefix + ".token", prefix + ".pending-pairing"]
        defer { for key in keys { Keychain.delete(key) } }
        for key in keys {
            var attributes = query(key)
            attributes[kSecValueData as String] = Data("retained-credential-fixture".utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
        }
        XCTAssertTrue(Keychain.migrateComputerCredentials())
        for key in keys {
            // Check the OS protection before reading through the wrapper: a
            // receipt must be protected even if the phone never scans again.
            XCTAssertEqual(try storedAccessibility(key), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            XCTAssertEqual(Keychain.get(key), "retained-credential-fixture")
        }
    }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.oblien.mindwire",
         kSecAttrAccount as String: key]
    }

    private func storedAccessibility(_ key: String) throws -> String {
        var attributes = query(key)
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(attributes as CFDictionary, &result), errSecSuccess)
        let item = try XCTUnwrap(result as? [String: Any])
        return try XCTUnwrap(item[kSecAttrAccessible as String] as? String)
    }
}
