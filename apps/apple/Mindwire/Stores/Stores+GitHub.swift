import Foundation

extension Notification.Name {
    static let gitHubAccountsChanged = Notification.Name("mindwire.github.accountsChanged")
}

extension Stores {
    func gitHubAccounts() -> [GitHubAccount] {
        github.list().sorted { $0.createdAt > $1.createdAt }
    }

    /// True when the workspace is self-hosted (its server connection is remote/SSH), so `gh`
    /// could run there — gates the gh-CLI connect option.
    func workspaceSupportsGh(_ workspaceId: String) -> Bool {
        guard let workspace = workspaces.get(workspaceId),
              let serverId = workspace.runtime.serverId,
              let connection = connections.get(serverId) else { return false }
        return connection.remote != nil
    }

    @discardableResult
    func connectToken(login: String, name: String?, token: String, avatarUrl: String? = nil,
                      label: String? = nil, checked: Bool = false) throws -> GitHubAccount {
        let account = GitHubAccount(id: newId(), login: login, name: name, label: GitHubAccount.cleanLabel(label),
                                    lastCheck: checked ? .init(checkedAt: isoNow(), succeeded: true) : nil, avatarUrl: avatarUrl,
                                    mode: .token, workspaceId: nil, createdAt: isoNow())
        guard Keychain.set(token, for: KeychainKey.githubToken(account.id)) else {
            throw BackendError.message(t("github.connect.storageFailed"))
        }
        saveGitHubAccount(account)
        return account
    }

    /// Keep the connection ID stable so replacing an expired token preserves all
    /// project bindings. Older app builds used "you" before checking identity.
    @discardableResult
    func replaceGitHubToken(accountId: String, user: GHRestUser, token: String,
                            label: String? = nil) throws -> GitHubAccount {
        guard var account = github.get(accountId), account.mode == .token else {
            throw BackendError.message(t("github.accounts.tokenMissing"))
        }
        guard account.login == "you" || account.login.caseInsensitiveCompare(user.login) == .orderedSame else {
            throw BackendError.message(t("github.connect.wrongAccount"))
        }
        guard Keychain.set(token, for: KeychainKey.githubToken(account.id)) else {
            throw BackendError.message(t("github.connect.storageFailed"))
        }
        account.login = user.login
        account.name = user.name
        account.avatarUrl = user.avatarUrl
        if let label { account.label = GitHubAccount.cleanLabel(label) }
        account.lastCheck = .init(checkedAt: isoNow(), succeeded: true)
        saveGitHubAccount(account)
        return account
    }

    @discardableResult
    func connectOblienApp(login: String, name: String?, avatarUrl: String? = nil) -> GitHubAccount {
        let account = GitHubAccount(id: newId(), login: login, name: name, avatarUrl: avatarUrl,
                                    mode: .oblienApp, workspaceId: nil, createdAt: isoNow())
        saveGitHubAccount(account)
        return account
    }

    @discardableResult
    func connectGh(workspaceId: String, login: String) -> GitHubAccount {
        let account = GitHubAccount(id: newId(), login: login, name: nil, avatarUrl: nil,
                                    mode: .ghCli, workspaceId: workspaceId, createdAt: isoNow())
        saveGitHubAccount(account)
        return account
    }

    /// Register an SSH key (generated in-app or pasted by the user) as a GitHub identity. The full
    /// OpenSSH **private key PEM** lives in the Keychain; there's no API listing, so clones go by URL
    /// over SSH using that key.
    @discardableResult
    func connectSSHKey(label: String, privateKeyPEM: String, checked: Bool = false) throws -> GitHubAccount {
        guard SSHKey.isPrivateKeyPEM(privateKeyPEM), SSHKey.privateKey(from: privateKeyPEM) != nil else {
            throw BackendError.message(t("github.credential.invalidKey"))
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = GitHubAccount(id: newId(), login: trimmed.isEmpty ? "SSH key" : trimmed,
                                    name: nil, label: GitHubAccount.cleanLabel(label),
                                    lastCheck: checked ? .init(checkedAt: isoNow(), succeeded: true) : nil,
                                    avatarUrl: nil, mode: .sshKey, workspaceId: nil,
                                    createdAt: isoNow())
        guard Keychain.set(privateKeyPEM, for: KeychainKey.githubSshKey(account.id)) else {
            throw BackendError.message(t("github.connect.storageFailed"))
        }
        saveGitHubAccount(account)
        return account
    }

    @discardableResult
    func renameGitHubAccount(_ id: String, label: String) throws -> GitHubAccount {
        guard var account = github.get(id) else { throw BackendError.message(t("github.accounts.tokenMissing")) }
        account.label = GitHubAccount.cleanLabel(label)
        saveGitHubAccount(account)
        return account
    }

    @discardableResult
    func replaceGitHubSSHKey(accountId: String, label: String, privateKeyPEM: String) throws -> GitHubAccount {
        guard var account = github.get(accountId), account.mode == .sshKey else {
            throw BackendError.message(t("github.accounts.tokenMissing"))
        }
        guard SSHKey.isPrivateKeyPEM(privateKeyPEM), SSHKey.privateKey(from: privateKeyPEM) != nil else {
            throw BackendError.message(t("github.credential.invalidKey"))
        }
        guard Keychain.set(privateKeyPEM, for: KeychainKey.githubSshKey(account.id)) else {
            throw BackendError.message(t("github.connect.storageFailed"))
        }
        account.label = GitHubAccount.cleanLabel(label)
        account.lastCheck = .init(checkedAt: isoNow(), succeeded: true)
        saveGitHubAccount(account)
        return account
    }

    func recordGitHubCheck(_ id: String, succeeded: Bool) {
        guard var account = github.get(id) else { return }
        account.lastCheck = .init(checkedAt: isoNow(), succeeded: succeeded)
        saveGitHubAccount(account)
    }

    @discardableResult
    func removeGitHubAccount(_ id: String) -> Bool {
        guard let account = github.get(id) else { return true }
        let removed: Bool
        switch account.mode {
        case .token: removed = Keychain.delete(KeychainKey.githubToken(id))
        case .sshKey: removed = Keychain.delete(KeychainKey.githubSshKey(id))
        case .oblienApp, .ghCli: removed = true
        }
        guard removed else { return false }
        github.remove(id)
        NotificationCenter.default.post(name: .gitHubAccountsChanged, object: self)
        return true
    }

    private func saveGitHubAccount(_ account: GitHubAccount) {
        github.save(account)
        NotificationCenter.default.post(name: .gitHubAccountsChanged, object: self)
    }
}
