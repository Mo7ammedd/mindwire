import XCTest
import NIOSSH
@testable import Mindwire

final class SSHKeyTests: XCTestCase {
    func testPastedOpenSSHKeyAndStoredSeedAuthenticateWithTheSamePublicKey() throws {
        let generated = SSHKey.generate(comment: "Mindwire test")
        // Different comment sizes exercise every OpenSSH block-padding length.
        for length in 0..<16 {
            let pem = try XCTUnwrap(SSHKey.openSSHPrivateKeyPEM(fromSeedBase64: generated.privateSeedBase64,
                                                              comment: String(repeating: "x", count: length)))
            let parsed = try XCTUnwrap(SSHKey.privateKey(from: pem))
            XCTAssertEqual(String(openSSHPublicKey: parsed.publicKey), String(openSSHPublicKey: generated.nioPrivateKey.publicKey))
            guard case .privateKey = SSHConnection.authentication(method: .key, secret: pem) else {
                return XCTFail("Pasted keys must use SSH public-key authentication")
            }
        }
        let seedKey = try XCTUnwrap(SSHKey.privateKey(from: generated.privateSeedBase64))
        XCTAssertEqual(String(openSSHPublicKey: seedKey.publicKey), String(openSSHPublicKey: generated.nioPrivateKey.publicKey))
    }

    func testMalformedUnsupportedAndTruncatedKeysFailBeforeConnecting() throws {
        let generated = SSHKey.generate(comment: "fixture")
        let pem = try XCTUnwrap(SSHKey.openSSHPrivateKeyPEM(fromSeedBase64: generated.privateSeedBase64, comment: "fixture"))
        for value in ["", "not a key", generated.openSSHPublicLine,
                      "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----",
                      String(pem.prefix(120)), pem.replacingOccurrences(of: "b3BlbnNzaC", with: "AAAAAAAAAA")] {
            XCTAssertNil(SSHKey.privateKey(from: value))
            guard case .unavailable = SSHConnection.authentication(method: .key, secret: value) else {
                return XCTFail("Invalid key input must not become a password attempt")
            }
        }
    }
}
