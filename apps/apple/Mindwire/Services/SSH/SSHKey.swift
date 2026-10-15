import Foundation
import Crypto
import NIOSSH

/// SSH key support for keyless server auth: generate an ed25519 keypair, expose the OpenSSH
/// public line to install on the server, persist the private seed in the Keychain, and
/// reconstruct a `NIOSSHPrivateKey` for auth.
enum SSHKey {
    struct Generated {
        let privateSeedBase64: String   // → Keychain
        let openSSHPublicLine: String   // → server ~/.ssh/authorized_keys
        let nioPrivateKey: NIOSSHPrivateKey
    }

    static func generate(comment: String) -> Generated {
        let priv = Curve25519.Signing.PrivateKey()
        return Generated(
            privateSeedBase64: priv.rawRepresentation.base64EncodedString(),
            openSSHPublicLine: openSSHLine(publicKey: priv.publicKey, comment: comment),
            nioPrivateKey: NIOSSHPrivateKey(ed25519Key: priv)
        )
    }

    /// Reconstruct the private key from a Keychain-stored seed (base64 of `rawRepresentation`).
    static func loadPrivateKey(_ keychainKey: String) -> NIOSSHPrivateKey? {
        Keychain.get(keychainKey).flatMap(privateKey(from:))
    }

    /// Accept the app's stored seed and standard, unencrypted OpenSSH Ed25519 keys.
    /// Validate lengths, check values, public key and padding before using the seed.
    static func privateKey(from text: String) -> NIOSSHPrivateKey? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seed = Data(base64Encoded: text), seed.count == 32,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) {
            return NIOSSHPrivateKey(ed25519Key: key)
        }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard text.utf8.count < 65_536, lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----",
              let data = Data(base64Encoded: lines.dropFirst().dropLast().joined()),
              data.starts(with: Data("openssh-key-v1\0".utf8)) else { return nil }
        var envelope = KeyReader(data: data, offset: 15)
        guard envelope.string() == "none", envelope.string() == "none", envelope.field() == Data(),
              envelope.integer() == 1, let publicBlob = envelope.field(), let privateBlob = envelope.field(),
              envelope.remaining.isEmpty else { return nil }
        var section = KeyReader(data: privateBlob)
        guard let check = section.integer(), section.integer() == check,
              section.string() == "ssh-ed25519", let publicKey = section.field(), publicKey.count == 32,
              let privateKey = section.field(), privateKey.count == 64, section.field() != nil,
              privateBlob.count % 8 == 0, section.remaining.count <= 8,
              Array(section.remaining) == (0..<section.remaining.count).map { UInt8($0 + 1) },
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey.prefix(32)),
              key.publicKey.rawRepresentation == publicKey,
              Data(privateKey.suffix(32)) == publicKey else { return nil }
        var published = KeyReader(data: publicBlob)
        guard published.string() == "ssh-ed25519", published.field() == publicKey, published.remaining.isEmpty else { return nil }
        return NIOSSHPrivateKey(ed25519Key: key)
    }

    private struct KeyReader {
        let data: Data
        var offset = 0
        var remaining: Data { data.subdata(in: offset..<data.count) }
        mutating func integer() -> UInt32? {
            guard data.count - offset >= 4 else { return nil }
            defer { offset += 4 }
            return data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        mutating func field() -> Data? {
            guard let count = integer(), Int(count) <= data.count - offset else { return nil }
            defer { offset += Int(count) }
            return data.subdata(in: offset..<offset + Int(count))
        }
        mutating func string() -> String? { field().flatMap { String(data: $0, encoding: .utf8) } }
    }

    /// Shell that appends the public key to `~/.ssh/authorized_keys` (skips if already present).
    static func installCommand(publicLine: String) -> [String] {
        let quoted = SSHConnection.commandString([publicLine])
        let script = "umask 077; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
            + "chmod 600 ~/.ssh/authorized_keys && "
            + "{ grep -qxF -- \(quoted) ~/.ssh/authorized_keys || printf '%s\\n' \(quoted) >> ~/.ssh/authorized_keys; }"
        return ["sh", "-c", script]
    }

    // OpenSSH wire format: string("ssh-ed25519") + string(32-byte raw pubkey), base64-encoded.
    private static func openSSHLine(publicKey: Curve25519.Signing.PublicKey, comment: String) -> String {
        var blob = Data()
        func writeString(_ bytes: Data) {
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
            blob.append(bytes)
        }
        writeString(Data("ssh-ed25519".utf8))
        writeString(publicKey.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    /// Loose check that a string is a PEM private key (generated or user-pasted), before storing it.
    static func isPrivateKeyPEM(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("-----BEGIN") && t.contains("PRIVATE KEY-----")
    }

    /// Serialize a stored Curve25519 seed into an unencrypted OpenSSH **private** key (PEM), so it
    /// can be dropped on a workspace as an `ssh -i` identity to `git clone` over SSH. Follows the
    /// `PROTOCOL.key` format; verified to round-trip through `ssh-keygen -y`.
    static func openSSHPrivateKeyPEM(fromSeedBase64 seedBase64: String, comment: String) -> String? {
        guard let seed = Data(base64Encoded: seedBase64),
              let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        let pub = priv.publicKey.rawRepresentation
        let priv64 = seed + pub   // OpenSSH ed25519 private = seed(32) || pub(32)

        func field(_ d: Data) -> Data {
            var len = UInt32(d.count).bigEndian
            var out = Data()
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(d)
            return out
        }
        func field(_ s: String) -> Data { field(Data(s.utf8)) }

        var pubBlob = Data()
        pubBlob.append(field("ssh-ed25519"))
        pubBlob.append(field(pub))

        let check = UInt32.random(in: 0...UInt32.max)
        var section = Data()
        var c = check.bigEndian
        withUnsafeBytes(of: &c) { section.append(contentsOf: $0) }  // check1
        withUnsafeBytes(of: &c) { section.append(contentsOf: $0) }  // check2
        section.append(field("ssh-ed25519"))
        section.append(field(pub))
        section.append(field(priv64))
        section.append(field(comment))
        var pad: UInt8 = 1
        while section.count % 8 != 0 { section.append(pad); pad += 1 }

        var body = Data("openssh-key-v1\0".utf8)
        body.append(field("none"))   // ciphername
        body.append(field("none"))   // kdfname
        body.append(field(Data()))   // kdfoptions (empty)
        var nkeys = UInt32(1).bigEndian
        withUnsafeBytes(of: &nkeys) { body.append(contentsOf: $0) }
        body.append(field(pubBlob))
        body.append(field(section))

        let b64 = body.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 70).map { i -> String in
            let s = b64.index(b64.startIndex, offsetBy: i)
            let e = b64.index(s, offsetBy: min(70, b64.count - i))
            return String(b64[s..<e])
        }.joined(separator: "\n")
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(lines)\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
