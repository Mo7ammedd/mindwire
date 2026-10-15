import Foundation
import Observation

/// Keeps direct-entry credentials independent of repository browsing and its asynchronous reads.
@MainActor
@Observable
final class GitHubRepoPickerModel {
    enum Mode: Hashable { case repositories, link }
    static let publicAccountID = "public"

    var mode: Mode
    private(set) var accounts: [GitHubAccount] = []
    var browseAccountID: String {
        didSet {
            guard browseAccountID != oldValue else { return }
            picked = nil
            owners = []; repos = []; ownerID = ""
        }
    }
    var linkAccountID: String
    var ownerID: String {
        didSet {
            guard ownerID != oldValue else { return }
            repos = []
            loadedRepoKey = nil
            if picked?.owner.caseInsensitiveCompare(ownerID) != .orderedSame { picked = nil }
        }
    }
    var picked: GitHubRepo?
    var repositoryInput: String
    var query = ""
    var refreshID = 0
    private(set) var owners: [GitHubOwner] = []
    private(set) var repos: [GitHubRepo] = []
    private(set) var loadingOwners = false
    private(set) var loadingRepos = false
    private(set) var checkingLinkAccess = false
    private(set) var needsBrowseLogin = false
    private(set) var error: String?

    private var linkLoginRequired = false
    private var loadedAccounts = false
    private let hasInitialSelection: Bool
    private var ownerLoadID = UUID()
    private var repoLoadID = UUID()
    private var loadingRepoKey: String?
    private var loadedRepoKey: String?
    private let auth: OblienAuth
    private let makeService: (GitHubAccount, Stores) -> GitHubService

    init(selectedRepo: GitHubRepo? = nil, selectedAccount: GitHubAccount? = nil,
         auth: OblienAuth? = nil,
         makeService: @escaping (GitHubAccount, Stores) -> GitHubService = {
             BackendFactory.githubService(for: $0, stores: $1)
         }) {
        self.auth = auth ?? .shared
        self.makeService = makeService
        hasInitialSelection = selectedRepo != nil
        mode = selectedRepo != nil && (selectedAccount == nil || selectedAccount?.mode == .sshKey) ? .link : .repositories
        browseAccountID = selectedAccount?.mode == .sshKey ? "" : selectedAccount?.id ?? ""
        linkAccountID = selectedAccount?.id ?? Self.publicAccountID
        ownerID = selectedRepo?.owner ?? ""
        picked = selectedRepo
        repositoryInput = selectedRepo?.fullName ?? ""
    }

    var browseAccounts: [GitHubAccount] { accounts.filter { $0.mode != .sshKey } }
    var browseAccount: GitHubAccount? { browseAccounts.first { $0.id == browseAccountID } }
    var linkAccount: GitHubAccount? { accounts.first { $0.id == linkAccountID } }
    var linkAccountMissing: Bool { linkAccountID != Self.publicAccountID && linkAccount == nil }
    var needsLinkLogin: Bool { linkAccount?.mode == .oblienApp && !auth.authenticated && (linkLoginRequired || auth.isSignedOut) }
    var inputRepository: GitHubRepo? { GitHubRepo.fromGitInput(repositoryInput) }
    var visibleRepos: [GitHubRepo] { GitHubFilter.byName(repos, query: query) }
    var selectedAccount: GitHubAccount? { mode == .link ? linkAccount : browseAccount }
    var selection: GitHubRepo? { mode == .link ? inputRepository : picked }
    var canSelect: Bool {
        guard selection != nil else { return false }
        switch mode {
        case .link: return !linkAccountMissing && !needsLinkLogin && !checkingLinkAccess
        case .repositories:
            return browseAccount != nil && !needsBrowseLogin && !loadingOwners && !loadingRepos
                && repos.contains { $0.id == picked?.id }
        }
    }

    func reloadAccounts(_ values: [GitHubAccount], workspaceId: String, preferred: String? = nil) {
        accounts = values.filter { $0.mode != .ghCli || $0.workspaceId == workspaceId }
        if let preferred, let added = accounts.first(where: { $0.id == preferred }) {
            linkAccountID = added.id
            if added.mode == .sshKey { mode = .link }
            else { browseAccountID = added.id }
        }
        if browseAccount == nil {
            if hasInitialSelection && !loadedAccounts && linkAccountMissing { mode = .link }
            browseAccountID = browseAccounts.first?.id ?? ""
        }
        if !loadedAccounts && !hasInitialSelection && browseAccounts.isEmpty { mode = .link }
        loadedAccounts = true
    }

    func checkLinkAccess() async {
        let account = linkAccount
        linkLoginRequired = false
        checkingLinkAccess = account?.mode == .oblienApp
        guard checkingLinkAccess else { return }
        defer { if linkAccountID == account?.id { checkingLinkAccess = false } }
        let authorized = await auth.ensure()
        guard !Task.isCancelled, linkAccountID == account?.id else { return }
        linkLoginRequired = !authorized
    }

    func loadOwners(stores: Stores) async {
        let requestID = UUID()
        ownerLoadID = requestID
        repoLoadID = UUID()
        loadingRepoKey = nil
        loadedRepoKey = nil
        let preferredOwner = ownerID
        repos = []; owners = []; error = nil; needsBrowseLogin = false
        loadingOwners = false; loadingRepos = false
        guard let account = browseAccount else { return }
        loadingOwners = true
        defer { if ownerLoadID == requestID { loadingOwners = false } }
        do {
            if account.mode == .oblienApp, !(await auth.ensure()) {
                guard !Task.isCancelled, ownerLoadID == requestID, browseAccountID == account.id else { return }
                needsBrowseLogin = true
                return
            }
            let values = try await makeService(account, stores).owners(for: account)
            guard !Task.isCancelled, ownerLoadID == requestID, browseAccountID == account.id else { return }
            owners = values
            loadingOwners = false
            ownerID = values.first { $0.login.caseInsensitiveCompare(preferredOwner) == .orderedSame }?.id
                ?? values.first?.id ?? ""
            // The owner can stay the same after a refresh; still fetch its new repository list.
            await loadRepos(stores: stores)
        } catch {
            guard !Task.isCancelled, ownerLoadID == requestID, browseAccountID == account.id else { return }
            self.error = error.localizedDescription
        }
    }

    func loadRepos(stores: Stores) async {
        guard let account = browseAccount, let owner = owners.first(where: { $0.id == ownerID }) else { return }
        let key = "\(account.id):\(owner.id):\(refreshID)"
        guard loadingRepoKey != key, loadedRepoKey != key else { return }
        let requestID = UUID()
        repoLoadID = requestID
        loadingRepoKey = key
        loadingRepos = true
        defer {
            if repoLoadID == requestID { loadingRepos = false; loadingRepoKey = nil }
        }
        do {
            let values = try await makeService(account, stores).repos(account: account, owner: owner, query: nil)
            guard !Task.isCancelled, repoLoadID == requestID, browseAccountID == account.id, ownerID == owner.id else { return }
            repos = values
            loadedRepoKey = key
            if let picked { self.picked = values.first { $0.id == picked.id } }
            error = nil
        } catch {
            guard !Task.isCancelled, repoLoadID == requestID, browseAccountID == account.id, ownerID == owner.id else { return }
            repos = []
            loadedRepoKey = key
            self.error = error.localizedDescription
        }
    }
}
