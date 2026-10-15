import XCTest
@testable import Mindwire

@MainActor
final class GitHubAccessTests: XCTestCase {
    func testRepositoryPickerKeepsPublicAndTokenLinksIndependentOfOblienLogin() async throws {
        let stores = try fixtureStores()
        let cloud = GitHubAccount(id: "cloud", login: "personal", mode: .oblienApp, createdAt: isoNow())
        let token = GitHubAccount(id: "token", login: "work", mode: .token, createdAt: isoNow())
        let service = RepositoryPickerFixture()
        let model = GitHubRepoPickerModel(auth: OblienAuth { AuthStatus(authenticated: false) }, makeService: { _, _ in service })
        model.reloadAccounts([cloud, token], workspaceId: "workspace")
        model.mode = .link
        model.repositoryInput = "https://github.com/octocat/app.git"
        await model.loadOwners(stores: stores)
        XCTAssertTrue(model.needsBrowseLogin)
        XCTAssertEqual(service.ownerReads, 0)
        XCTAssertTrue(model.canSelect, "An unrelated browsing login must not block a public URL")
        XCTAssertNil(model.selectedAccount)

        model.linkAccountID = cloud.id
        await model.checkLinkAccess()
        XCTAssertFalse(model.canSelect)
        XCTAssertTrue(model.needsLinkLogin)
        model.linkAccountID = token.id
        await model.checkLinkAccess()
        XCTAssertTrue(model.canSelect, "Independent GitHub credentials do not require Oblien")
        XCTAssertEqual(model.selectedAccount?.id, token.id)
        model.linkAccountID = GitHubRepoPickerModel.publicAccountID
        await model.checkLinkAccess()
        XCTAssertNil(model.selectedAccount)
        XCTAssertTrue(model.canSelect)
        XCTAssertEqual(model.selection?.fullName, "octocat/app")
    }

    func testRepositoryPickerRestoresOwnerAndSelectionAndReusesListingAcrossModes() async throws {
        let stores = try fixtureStores()
        let account = GitHubAccount(id: "work", login: "developer", mode: .token, createdAt: isoNow())
        let other = GitHubAccount(id: "personal", login: "personal", mode: .token, createdAt: isoNow())
        let repo = try XCTUnwrap(GitHubRepo.fromGitInput("team/app"))
        let service = RepositoryPickerFixture(owners: ["developer", "team"], repositories: [repo])
        let model = GitHubRepoPickerModel(selectedRepo: repo, selectedAccount: account, makeService: { _, _ in service })
        model.reloadAccounts([other, account], workspaceId: "workspace")
        await model.loadOwners(stores: stores)
        // The view's owner task can arrive after the account task has already loaded that owner.
        await model.loadRepos(stores: stores)
        XCTAssertEqual(model.browseAccountID, account.id)
        XCTAssertEqual(model.ownerID, "team")
        XCTAssertEqual(model.selection, repo)
        XCTAssertTrue(model.canSelect)
        XCTAssertEqual(service.repoReads, 1)

        model.mode = .link
        model.repositoryInput = "https://github.com/another/new-project"
        model.linkAccountID = GitHubRepoPickerModel.publicAccountID
        XCTAssertNil(model.selectedAccount)
        model.mode = .repositories
        XCTAssertEqual(model.selection, repo)
        XCTAssertEqual(model.selectedAccount?.id, account.id)
        model.query = " TEAM/APP\n"
        XCTAssertEqual(model.visibleRepos, [repo])
        model.mode = .link
        XCTAssertEqual(model.selection?.fullName, "another/new-project")
        XCTAssertNil(model.selectedAccount, "Switching tabs must not replace explicit public access")
        XCTAssertEqual(service.ownerReads, 1)
        XCTAssertEqual(service.repoReads, 1)
    }

    func testLateRepositoryAccountReadCannotReplaceNewAccountOrTypedLink() async throws {
        let stores = try fixtureStores()
        let old = GitHubAccount(id: "old", login: "old", mode: .token, createdAt: isoNow())
        let new = GitHubAccount(id: "new", login: "new", mode: .token, createdAt: isoNow())
        let held = RepositoryPickerFixture(owners: ["old"], repositories: [])
        held.holdOwners = true
        let repo = try XCTUnwrap(GitHubRepo.fromGitInput("new/app"))
        let current = RepositoryPickerFixture(owners: ["new"], repositories: [repo])
        let model = GitHubRepoPickerModel(makeService: { account, _ in account.id == old.id ? held : current })
        model.reloadAccounts([old, new], workspaceId: "workspace")
        let loading = Task { await model.loadOwners(stores: stores) }
        for _ in 0..<100 {
            if held.ownerGate != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(held.ownerGate)
        model.browseAccountID = new.id
        await model.loadOwners(stores: stores)
        model.mode = .link
        model.repositoryInput = "octocat/public-app"
        held.releaseOwners()
        await loading.value
        XCTAssertEqual(model.ownerID, "new")
        XCTAssertEqual(model.repos, [repo])
        XCTAssertEqual(model.selection?.fullName, "octocat/public-app")
        XCTAssertNil(model.selectedAccount)
        XCTAssertTrue(model.canSelect)
    }

    func testRepositoryPickerNeverSubstitutesAMissingOrOtherWorkspaceCredential() throws {
        let missing = GitHubAccount(id: "missing", login: "work", mode: .sshKey, createdAt: isoNow())
        let other = GitHubAccount(id: "personal", login: "personal", mode: .token, createdAt: isoNow())
        let cli = GitHubAccount(id: "server", login: "work", mode: .ghCli, workspaceId: "other", createdAt: isoNow())
        let repo = try XCTUnwrap(GitHubRepo.fromGitInput("work/private"))
        let model = GitHubRepoPickerModel(selectedRepo: repo, selectedAccount: missing)
        model.reloadAccounts([other, cli], workspaceId: "workspace")
        XCTAssertEqual(model.accounts.map(\.id), [other.id])
        XCTAssertEqual(model.selection, repo)
        XCTAssertTrue(model.linkAccountMissing)
        XCTAssertFalse(model.canSelect)
        XCTAssertNil(model.selectedAccount)
        model.linkAccountID = GitHubRepoPickerModel.publicAccountID
        XCTAssertTrue(model.canSelect, "Only an explicit access choice may change credentials")
    }

    func testGitHubRepositoryInputRejectsOtherHostsAndEmbeddedCredentials() {
        for value in ["octocat/app", "github.com/octocat/app", "https://github.com/octocat/app.git",
                      "git@github.com:octocat/app.git", "ssh://git@github.com/octocat/app",
                      "  octocat/app  ", "https://github.com/octocat/app/", "https://github.com/octocat/app.git/"] {
            XCTAssertEqual(GitHubRepo.fromGitInput(value)?.fullName, "octocat/app", value)
        }
        for value in ["https://github.com.evil.invalid/octocat/app", "https://evil.invalid/github.com/octocat/app",
                      "http://github.com/octocat/app", "https://token@github.com/octocat/app",
                      "https://github.com:444/octocat/app", "https://github.com/octocat/app?token=secret",
                      "https://github.com/octocat/%2e%2e", "https://github.com/octocat/app/extra",
                      "octocat/app\nother"] {
            XCTAssertNil(GitHubRepo.fromGitInput(value), value)
        }
    }

    func testDirectRepositoryClonesSupportPublicAccessAndKeepExplicitCredentials() async throws {
        let stores = try fixtureStores()
        let account = try stores.connectToken(login: "work", name: nil, token: "clone-access-fixture")
        defer { stores.removeGitHubAccount(account.id) }
        let workspace = Workspace(id: UUID().uuidString, name: "Workspace", runtime: .server(serverId: "clone-fixture"),
                                  createdAt: isoNow())
        let remote = WorkspaceRemoteFixture()
        remote.supportsProjectOperations = true
        remote.supportsGitAccess = true
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote },
            resolveWorkspace: { $0 == workspace.id ? workspace : nil })
        var requests: [ProjectCreateRequest] = []
        remote.onStart = { request in
            requests.append(request)
            let operation = ProjectOperation(id: request.id, source: request.source, name: request.name, path: request.path,
                repoUrl: request.repoUrl, authKind: request.auth?.kind, gitConnection: request.gitConnection,
                status: "running", phase: "cloning", createdAt: workspace.createdAt,
                updatedAt: workspace.createdAt, sequence: 1, attempt: 1)
            remote.operations.append(operation)
            return operation
        }
        let model = ProjectCreationModel()
        for (index, input) in ["octocat/app", "https://github.com/octocat/app.git/", "git@github.com:octocat/app.git"].enumerated() {
            let repo = try XCTUnwrap(GitHubRepo.fromGitInput(input))
            let operation = await model.clone(repo: repo, account: nil, name: "Public \(index)", workspaceId: workspace.id,
                                               destination: "/work/public-\(index)", stores: stores)
            XCTAssertEqual(operation?.status, "running", model.errorMessage ?? "")
            let request = try XCTUnwrap(requests.last)
            XCTAssertEqual(request.repoUrl, "https://github.com/octocat/app.git")
            XCTAssertNil(request.auth, "Public selection must not use another account saved on this phone")
            XCTAssertNil(request.gitConnection)
        }

        let repo = try XCTUnwrap(GitHubRepo.fromGitInput("work/private-app"))
        let operation = await model.clone(repo: repo, account: account, name: "Private", workspaceId: workspace.id,
                                          destination: "/work/private", stores: stores, lifetime: .workspace)
        XCTAssertEqual(operation?.status, "running", model.errorMessage ?? "")
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.repoUrl, "https://github.com/work/private-app.git")
        XCTAssertEqual(request.auth?.kind, "token")
        XCTAssertEqual(request.auth?.token, "clone-access-fixture")
        XCTAssertEqual(request.gitConnection?.id, account.id)
        XCTAssertEqual(request.gitConnection?.lifetime, .workspace)
        XCTAssertFalse(String(describing: stores.defaults.dictionaryRepresentation()).contains("clone-access-fixture"))

        let anotherWorkspace = GitHubAccount(id: "other-cli", login: "work", mode: .ghCli,
                                             workspaceId: "another-workspace", createdAt: isoNow())
        let requestCount = requests.count
        let rejected = await model.clone(repo: repo, account: anotherWorkspace, name: "Wrong server", workspaceId: workspace.id,
                                         destination: "/work/rejected", stores: stores)
        XCTAssertNil(rejected)
        XCTAssertEqual(requests.count, requestCount, "A server's GitHub login cannot be used on another workspace")
        XCTAssertEqual(model.errorMessage, t("project.operation.accountWorkspace"))
    }

    func testTokenBrowsingIncludesPaginatedOrganizationAndCollaboratorRepositories() async throws {
        let stores = try fixtureStores()
        let account = try stores.connectToken(login: "octocat", name: nil, token: "test-token")
        defer { stores.removeGitHubAccount(account.id) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); GitHubFixtureProtocol.response = nil }
        GitHubFixtureProtocol.response = { request in
            XCTAssertEqual(request.url?.host, "api.github.com", "Token browsing must go directly to GitHub")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let url = try XCTUnwrap(request.url)
            if url.path == "/user" { return (200, Data(#"{"login":"octocat"}"#.utf8)) }
            XCTAssertEqual(url.path, "/user/repos", "Fine-grained tokens must not require organization membership access")
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            let rows: [[String: Any]]
            if page == "1" {
                rows = (0..<100).map { Self.repoJSON(owner: "team", name: "app-\($0)", kind: "Organization") }
            } else {
                XCTAssertEqual(page, "2")
                rows = [Self.repoJSON(owner: "collaborator", name: "shared", kind: "User")]
            }
            return (200, try JSONSerialization.data(withJSONObject: rows))
        }
        let service = TokenGitHubService(session: session)
        let owners = try await service.owners(for: account)
        XCTAssertEqual(Set(owners.map(\.login)), ["team", "collaborator"])
        XCTAssertEqual(owners.first { $0.login == "team" }?.kind, .org)
        let collaborator = try XCTUnwrap(owners.first { $0.login == "collaborator" })
        let repos = try await service.repos(account: account, owner: collaborator, query: nil)
        XCTAssertEqual(repos.map(\.fullName), ["collaborator/shared"])
    }

    func testResolverUsesSelectedKeychainCredentialWithoutSavingItInMetadata() async throws {
        let stores = try fixtureStores()
        let first = try stores.connectToken(login: "personal", name: nil, token: "personal-secret-fixture")
        let second = try stores.connectToken(login: "work", name: nil, token: "work-secret-fixture")
        defer { stores.removeGitHubAccount(first.id); stores.removeGitHubAccount(second.id) }
        let connection = GitConnection(account: second)
        let auth = try await GitCredentialResolver.authorization(connection: connection,
            repoURL: "https://github.com/team/app.git", workspaceId: "server", stored: false, stores: stores)
        XCTAssertEqual(auth?.token, "work-secret-fixture")
        XCTAssertEqual(auth?.connectionId, second.id)
        let project = Project(id: "project", name: "App", workspaceId: "server", path: "/work/app",
            createdAt: isoNow(), gitConnection: connection)
        let encoded = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret-fixture"))
        XCTAssertFalse(String(describing: stores.defaults.dictionaryRepresentation()).contains("secret-fixture"))
        stores.removeGitHubAccount(second.id)
        do {
            _ = try await GitCredentialResolver.authorization(connection: connection,
                repoURL: project.repoUrl, workspaceId: "server", stored: false, stores: stores)
            XCTFail("A missing work account must not fall back to the personal account")
        } catch { XCTAssertTrue(error.localizedDescription.contains("work")) }
        var saved = connection
        saved.lifetime = .workspace
        let serverAuth = try await GitCredentialResolver.authorization(connection: saved,
            repoURL: project.repoUrl, workspaceId: "server", stored: true, stores: stores)
        XCTAssertNil(serverAuth, "A second device can use the explicitly saved server credential")
        let native = try await GitCredentialResolver.authorization(connection: .server,
            repoURL: nil, workspaceId: "server", stored: false, stores: stores)
        XCTAssertNil(native)
    }

    func testTurnAndAsyncReplyForwardAuthSeparatelyFromConversation() async throws {
        let channel = GitWireChannel()
        let transport = ExecDaemonTransport(channel: channel, agentType: "codex")
        let auth = ProjectCloneAuth(kind: "token", connectionId: "work", token: "private-wire-fixture")
        _ = try await transport.sendTurn(chatId: "chat", message: "Commit the fix", cwd: "/work/app", gitAuth: auth)
        try await transport.respondToRun("run", interactionId: "question",
            reply: .init(text: "Continue"), gitAuth: auth)
        let requests = await channel.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            let credential = try XCTUnwrap(object["gitAuth"] as? [String: String])
            XCTAssertEqual(credential["connectionId"], "work")
            XCTAssertEqual(credential["token"], "private-wire-fixture")
            XCTAssertNil(object["options"])
            XCTAssertFalse((object["message"] as? String ?? "").contains("private-wire-fixture"))
            XCTAssertFalse((object["text"] as? String ?? "").contains("private-wire-fixture"))
        }
        let legacy = try JSONDecoder().decode(DaemonHealth.self, from: Data(#"{"ok":true}"#.utf8))
        XCTAssertNil(legacy.gitAccessVersion)
    }

    func testReplacingLegacyTokenPreservesIDAndRejectsAnotherAccount() throws {
        let stores = try fixtureStores()
        let account = try stores.connectToken(login: "you", name: nil, token: "old-fixture")
        defer { stores.removeGitHubAccount(account.id) }
        let user = try JSONDecoder().decode(GHRestUser.self, from: Data(#"{"login":"octocat","name":"Octocat"}"#.utf8))
        try stores.replaceGitHubToken(accountId: account.id, user: user, token: "new-fixture")
        XCTAssertEqual(stores.github.get(account.id)?.login, "octocat")
        XCTAssertEqual(Keychain.get(KeychainKey.githubToken(account.id)), "new-fixture")
        let other = try JSONDecoder().decode(GHRestUser.self, from: Data(#"{"login":"other"}"#.utf8))
        XCTAssertThrowsError(try stores.replaceGitHubToken(accountId: account.id, user: other, token: "wrong-fixture"))
        XCTAssertEqual(Keychain.get(KeychainKey.githubToken(account.id)), "new-fixture")
    }

    func testCloneIdempotencyDistinguishesConnectionAndLifetimeAcrossReopen() throws {
        let stores = try fixtureStores()
        func id(_ data: WorkspaceDataRepository, connection: String = "", lifetime: String = "") -> String {
            data.projectRequestID(workspaceId: "server", source: "clone", name: "App", path: "/work/app",
                repoUrl: "https://github.com/team/app.git", authKind: "token", connectionID: connection, lifetime: lifetime)
        }
        let data = WorkspaceDataRepository(stores: stores)
        let legacy = id(data)
        let personal = id(data, connection: "personal", lifetime: "run")
        XCTAssertNotEqual(personal, legacy)
        XCTAssertNotEqual(personal, id(data, connection: "work", lifetime: "run"))
        XCTAssertNotEqual(personal, id(data, connection: "personal", lifetime: "workspace"))
        let reopened = WorkspaceDataRepository(stores: stores)
        XCTAssertEqual(legacy, id(reopened))
        XCTAssertEqual(personal, id(reopened, connection: "personal", lifetime: "run"))
    }

    func testDaemonUpdateWaitsForRemoteGitOperation() async throws {
        let channel = GitWireChannel(activeGit: 1)
        let health = DaemonHealth(ok: true, gitAccessVersion: 1)
        do {
            try await DaemonUpdateGuard.requireIdle(http: DaemonHTTP(channel: channel, agentType: ""), health: health)
            XCTFail("An active pull must prevent a daemon replacement")
        } catch { XCTAssertEqual(error.localizedDescription, t("workspace.daemon.busy")) }
        let requests = await channel.requests
        XCTAssertEqual(requests.map(\.path), ["/workspace/git"])
    }

    private func fixtureStores() throws -> Stores {
        let suite = "github-access-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    nonisolated private static func repoJSON(owner: String, name: String, kind: String) -> [String: Any] {
        ["owner": ["login": owner, "type": kind], "name": name, "full_name": "\(owner)/\(name)",
         "private": true, "clone_url": "https://github.com/\(owner)/\(name).git",
         "ssh_url": "git@github.com:\(owner)/\(name).git"]
    }
}

@MainActor
private final class RepositoryPickerFixture: GitHubService {
    let ownerNames: [String]
    let repositories: [GitHubRepo]
    var ownerReads = 0
    var repoReads = 0
    var holdOwners = false
    var ownerGate: CheckedContinuation<Void, Never>?

    init(owners: [String] = [], repositories: [GitHubRepo] = []) {
        ownerNames = owners
        self.repositories = repositories
    }
    func owners(for account: GitHubAccount) async throws -> [GitHubOwner] {
        ownerReads += 1
        if holdOwners { await withCheckedContinuation { ownerGate = $0 } }
        return ownerNames.map { .init(login: $0, kind: .user) }
    }
    func releaseOwners() { holdOwners = false; ownerGate?.resume(); ownerGate = nil }
    func repos(account: GitHubAccount, owner: GitHubOwner, query: String?) async throws -> [GitHubRepo] {
        repoReads += 1
        return repositories.filter { $0.owner == owner.login }
    }
    func authorization(repo: GitHubRepo?, account: GitHubAccount) async throws -> ProjectCloneAuth {
        XCTFail("Browsing must not acquire clone credentials")
        throw URLError(.unsupportedURL)
    }
}

private actor GitWireChannel: DaemonChannel {
    nonisolated let label = "git-wire-fixture"
    struct Request { let path: String; let body: Data }
    private(set) var requests: [Request] = []
    private let activeGit: Int
    init(activeGit: Int = 0) { self.activeGit = activeGit }

    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        requests.append(.init(path: path, body: jsonBody ?? Data("{}".utf8)))
        if path == "/workspace/git" {
            return (200, #"{"storedConnectionIds":[],"activeOperations":\#(activeGit)}"#)
        }
        if path.hasPrefix("/turns") {
            return (202, #"{"id":"run","chatId":"chat","status":"running","createdAt":"2026-09-19T00:00:00Z"}"#)
        }
        if path.hasPrefix("/runs/run/respond") { return (202, "") }
        throw URLError(.unsupportedURL)
    }
}

private final class GitHubFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> (Int, Data))?
    static var response: ((URLRequest) throws -> (Int, Data))? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let response = Self.response, let url = request.url else { throw URLError(.badURL) }
            let (status, data) = try response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
