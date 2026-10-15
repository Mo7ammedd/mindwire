import Foundation
import Observation

/// One draft for add and edit. Validation finishes before Keychain is changed;
/// cancelling or rejecting a replacement leaves the original connection intact.
@MainActor @Observable
final class GitHubCredentialEditorModel {
    enum KeySource: Hashable { case generate, existing }
    let mode: GitHubAuthMode
    let account: GitHubAccount?
    var name: String
    var secret: String { didSet { if secret != oldValue { clearFeedback() } } }
    var keySource: KeySource = .generate { didSet { if keySource != oldValue { clearFeedback() } } }
    private(set) var working = false
    private(set) var report: GitHubCredentialReport?
    private(set) var error: String?

    private let initialSecret: String
    private let generatedSecret: String
    private var validatedSecret: String?
    private var validatedAt: Date?
    private var saved = false
    @ObservationIgnored private let verify: (GitHubAuthMode, String) async throws -> GitHubCredentialReport

    init(mode: GitHubAuthMode, account: GitHubAccount? = nil,
         verify: @escaping (GitHubAuthMode, String) async throws -> GitHubCredentialReport = {
             try await GitHubCredentialService().test(mode: $0, secret: $1)
         }) {
        self.mode = mode
        self.account = account
        self.name = account?.displayName ?? ""
        let saved = account.flatMap(GitHubCredentialService.secret) ?? ""
        self.secret = saved
        self.initialSecret = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        self.verify = verify
        if mode == .sshKey, account == nil {
            let key = SSHKey.generate(comment: "Mindwire")
            generatedSecret = SSHKey.openSSHPrivateKeyPEM(fromSeedBase64: key.privateSeedBase64, comment: "Mindwire") ?? ""
        } else { generatedSecret = "" }
    }

    var usesGeneratedKey: Bool { mode == .sshKey && account == nil && keySource == .generate }
    var hasSecret: Bool { mode == .token || mode == .sshKey }
    var value: String {
        (usesGeneratedKey ? generatedSecret : secret).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasChanges: Bool { account == nil || trimmedName != account?.displayName || value != initialSecret }
    var canSave: Bool {
        !working && !saved && !trimmedName.isEmpty && hasChanges
            && (!hasSecret || !value.isEmpty || (account != nil && value == initialSecret))
    }
    var canTest: Bool { hasSecret && !value.isEmpty && !working }

    func test() async {
        guard canTest else { return }
        working = true
        error = nil
        defer { working = false }
        do { _ = try await validate(reuse: false) }
        catch is CancellationError {}
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func save(stores: Stores) async -> GitHubAccount? {
        guard canSave else { return nil }
        working = true
        error = nil
        defer { working = false }
        do {
            // A rename works offline and never changes the saved secret.
            if let account, value == initialSecret {
                try Task.checkCancellation()
                let updated = try stores.renameGitHubAccount(account.id, label: trimmedName)
                saved = true
                return updated
            }
            let report = try await validate(reuse: true)
            try Task.checkCancellation()
            let updated: GitHubAccount
            if let account {
                if mode == .token, let user = report.user {
                    updated = try stores.replaceGitHubToken(accountId: account.id, user: user, token: value, label: trimmedName)
                } else {
                    updated = try stores.replaceGitHubSSHKey(accountId: account.id, label: trimmedName, privateKeyPEM: value + "\n")
                }
            } else if mode == .token, let user = report.user {
                updated = try stores.connectToken(login: user.login, name: user.name, token: value, avatarUrl: user.avatarUrl,
                                               label: trimmedName, checked: true)
            } else {
                updated = try stores.connectSSHKey(label: trimmedName, privateKeyPEM: value + "\n", checked: true)
            }
            saved = true
            return updated
        } catch is CancellationError { return nil }
        catch { if !Task.isCancelled { self.error = error.localizedDescription }; return nil }
    }

    private func validate(reuse: Bool) async throws -> GitHubCredentialReport {
        if reuse, let report, validatedSecret == value, let validatedAt, Date().timeIntervalSince(validatedAt) < 60 { return report }
        report = nil
        validatedSecret = nil
        let candidate = value
        let result = try await verify(mode, candidate)
        try Task.checkCancellation()
        guard candidate == value else { throw CancellationError() }
        if let account, mode == .token, let user = result.user,
           account.login != "you", account.login.caseInsensitiveCompare(user.login) != .orderedSame {
            throw BackendError.message(t("github.connect.wrongAccount"))
        }
        report = result
        validatedSecret = candidate
        validatedAt = Date()
        return result
    }

    private func clearFeedback() {
        report = nil
        validatedSecret = nil
        validatedAt = nil
        error = nil
    }
}
