import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class GitHubCredentialTests: XCTestCase {
    func testLegacyNamesMigrateWithoutChangingIdentityOrBinding() throws {
        let old = Data(#"{"id":"legacy","login":"octocat","name":"Octo Cat","mode":"token","createdAt":"2026-09-25T12:00:00Z"}"#.utf8)
        var account = try JSONDecoder().decode(GitHubAccount.self, from: old)
        XCTAssertEqual(account.displayName, "Octo Cat")
        XCTAssertNil(account.lastCheck)
        XCTAssertNotNil(account.addedDate)
        XCTAssertNotNil(GitHubConnectionCheck(checkedAt: isoNow(), succeeded: true).date,
                        "Checks use timestamps with fractional seconds")
        account.label = "  Work repositories  "
        let loaded = try JSONDecoder().decode(GitHubAccount.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(loaded.displayName, "Work repositories")
        XCTAssertEqual(loaded.name, "Octo Cat", "Credential labels must not overwrite GitHub's profile name")
        XCTAssertEqual(GitConnection(account: loaded).id, "legacy")
        XCTAssertEqual(GitConnection(account: loaded).login, "octocat")
    }

    func testRenamingWorksOfflineWithoutTouchingTheSecretOrLastCheck() async throws {
        let stores = try fixtureStores()
        let account = try stores.connectToken(login: "octocat", name: "Octo", token: "original-fixture", checked: true)
        defer { stores.removeGitHubAccount(account.id) }
        let model = GitHubCredentialEditorModel(mode: .token, account: account) { _, _ in
            XCTFail("Renaming should not make any network requests")
            throw URLError(.notConnectedToInternet)
        }
        model.name = "  Work  "
        let saved = await model.save(stores: stores)
        XCTAssertEqual(saved?.displayName, "Work")
        XCTAssertEqual(saved?.name, "Octo")
        XCTAssertEqual(saved?.lastCheck, account.lastCheck)
        XCTAssertEqual(saved?.id, account.id)
        XCTAssertEqual(Keychain.get(KeychainKey.githubToken(account.id)), "original-fixture")
    }

    func testRejectedReplacementKeepsNameSecretAndBindingsUntilAValidSave() async throws {
        let stores = try fixtureStores()
        let account = try stores.connectToken(login: "octocat", name: nil, token: "original-fixture", label: "Personal")
        defer { stores.removeGitHubAccount(account.id) }
        let model = GitHubCredentialEditorModel(mode: .token, account: account) { _, secret in
            if secret == "bad-fixture" { throw GitHubAPIError(status: 401, message: "Bad credentials", requiresSSO: false) }
            return Self.report(login: secret == "other-fixture" ? "someone-else" : "octocat")
        }
        model.name = "Work"
        model.secret = "bad-fixture"
        let failed = await model.save(stores: stores)
        XCTAssertNil(failed)
        XCTAssertEqual(stores.github.get(account.id)?.displayName, "Personal")
        XCTAssertEqual(Keychain.get(KeychainKey.githubToken(account.id)), "original-fixture")
        XCTAssertEqual(model.error, t("github.credential.tokenRejected"))
        model.secret = "other-fixture"
        let other = await model.save(stores: stores)
        XCTAssertNil(other)
        XCTAssertEqual(model.error, t("github.connect.wrongAccount"))
        XCTAssertEqual(Keychain.get(KeychainKey.githubToken(account.id)), "original-fixture")
        model.secret = "  replacement-fixture\n"
        let saved = await model.save(stores: stores)
        XCTAssertEqual(saved?.id, account.id)
        XCTAssertEqual(saved?.displayName, "Work")
        XCTAssertEqual(saved?.lastCheck?.succeeded, true)
        XCTAssertEqual(Keychain.get(KeychainKey.githubToken(account.id)), "replacement-fixture")
        XCTAssertFalse(String(describing: stores.defaults.dictionaryRepresentation()).contains("replacement-fixture"))
    }

    func testConcurrentAndRepeatedAddsOnlyCreateOneConnection() async throws {
        let stores = try fixtureStores()
        let verifier = CredentialVerifierFixture()
        let started = expectation(description: "Credential validation started")
        verifier.didStart = { started.fulfill() }
        let model = GitHubCredentialEditorModel(mode: .token, verify: verifier.verify)
        model.name = "Work"
        model.secret = "draft-fixture"
        let first = Task { await model.save(stores: stores) }
        await fulfillment(of: [started], timeout: 2)
        let duplicate = await model.save(stores: stores)
        XCTAssertNil(duplicate)
        XCTAssertEqual(verifier.calls, 1)
        verifier.finish(Self.report())
        let result = await first.value
        let added = try XCTUnwrap(result)
        defer { stores.removeGitHubAccount(added.id) }
        let repeatTap = await model.save(stores: stores)
        XCTAssertNil(repeatTap)
        XCTAssertEqual(stores.gitHubAccounts().count, 1)
    }

    func testTestingDoesNotSaveAndSaveReusesOnlyTheCurrentSuccessfulCheck() async throws {
        let stores = try fixtureStores()
        var calls = 0
        let model = GitHubCredentialEditorModel(mode: .token) { _, _ in calls += 1; return Self.report() }
        model.name = "Personal"
        model.secret = "first-fixture"
        await model.test()
        XCTAssertTrue(stores.gitHubAccounts().isEmpty)
        XCTAssertEqual(calls, 1)
        await model.test()
        XCTAssertEqual(calls, 2, "An explicit Test must bypass a previous successful check")
        model.secret = "second-fixture"
        XCTAssertNil(model.report)
        await model.test()
        XCTAssertEqual(calls, 3)
        let result = await model.save(stores: stores)
        let account = try XCTUnwrap(result)
        defer { stores.removeGitHubAccount(account.id) }
        XCTAssertEqual(calls, 3, "Saving immediately after a successful test should not send the same check twice")
        XCTAssertEqual(Keychain.get(KeychainKey.githubToken(account.id)), "second-fixture")
    }

    func testCancellationAndChangedDraftCannotSaveAnOldVerification() async throws {
        let stores = try fixtureStores()
        for cancel in [false, true] {
            let verifier = CredentialVerifierFixture()
            let started = expectation(description: "Credential validation started")
            verifier.didStart = { started.fulfill() }
            let model = GitHubCredentialEditorModel(mode: .token, verify: verifier.verify)
            model.name = "Personal"; model.secret = "old-draft"
            let task = Task { await model.save(stores: stores) }
            await fulfillment(of: [started], timeout: 2)
            if cancel { task.cancel() } else { model.secret = "new-draft" }
            verifier.finish(Self.report())
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertTrue(stores.gitHubAccounts().isEmpty)
            XCTAssertNil(model.error)
        }
    }

    func testSSHReplacementAndRemovalPreserveOtherCredentials() async throws {
        let stores = try fixtureStores()
        let original = try key()
        let replacement = try key()
        let account = try stores.connectSSHKey(label: "Build key", privateKeyPEM: original)
        let token = try stores.connectToken(login: "octocat", name: nil, token: "another-fixture")
        defer { stores.removeGitHubAccount(account.id); stores.removeGitHubAccount(token.id) }
        let model = GitHubCredentialEditorModel(mode: .sshKey, account: account) { mode, candidate in
            guard SSHKey.privateKey(from: candidate) != nil else { throw BackendError.message("Invalid key") }
            return .init(mode: mode)
        }
        model.name = "Deploy key"
        model.secret = replacement
        let result = await model.save(stores: stores)
        XCTAssertEqual(result?.id, account.id)
        XCTAssertEqual(result?.displayName, "Deploy key")
        XCTAssertEqual(GitHubCredentialService.publicKey(from: Keychain.get(KeychainKey.githubSshKey(account.id)) ?? ""),
                       GitHubCredentialService.publicKey(from: replacement))
        XCTAssertTrue(stores.removeGitHubAccount(account.id))
        XCTAssertNil(Keychain.get(KeychainKey.githubSshKey(account.id)))
        XCTAssertNil(stores.github.get(account.id))
        XCTAssertEqual(Keychain.get(KeychainKey.githubToken(token.id)), "another-fixture")
        XCTAssertNotNil(stores.github.get(token.id))
    }

    func testTokenCheckIsBoundedAndReportsOnlyVerifiedAccess() async throws {
        let session = fixtureSession()
        var paths: [String] = []
        CredentialHTTPFixture.respond = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            let url = try XCTUnwrap(request.url)
            paths.append(url.path)
            if url.path == "/user" {
                return (200, ["X-OAuth-Scopes": "repo, workflow", "GitHub-Authentication-Token-Expiration": "2026-10-01 00:00:00 UTC"],
                        Data(#"{"login":"octocat","name":"Octo"}"#.utf8))
            }
            XCTAssertEqual(url.query, "per_page=1")
            return (200, [:], Data("[]".utf8))
        }
        let result = try await GitHubCredentialService(session: session).testToken("fixture")
        XCTAssertEqual(paths, ["/user", "/user/repos"])
        XCTAssertEqual(result.user?.login, "octocat")
        XCTAssertEqual(result.scopes, ["repo", "workflow"])
        XCTAssertEqual(result.expiresAt, "2026-10-01 00:00:00 UTC")
        XCTAssertFalse(result.summary.lowercased().contains("push"))
        CredentialHTTPFixture.respond = { request in
            (200, ["X-OAuth-Scopes": ""], Data((request.url?.path == "/user" ? #"{"login":"octocat"}"# : "[]").utf8))
        }
        let fineGrained = try await GitHubCredentialService(session: session).testToken("fixture")
        XCTAssertNil(fineGrained.scopes, "An empty OAuth-scope header must not imply public-only access for fine-grained tokens")
    }

    func testSSHImportsRejectIncompleteKeysAndRawSeedsBeforeTestingOrSaving() async throws {
        let stores = try fixtureStores()
        let session = fixtureSession()
        CredentialHTTPFixture.respond = { _ in
            XCTFail("Invalid key material must be rejected before a network request")
            throw URLError(.badURL)
        }
        let generated = SSHKey.generate(comment: "fixture")
        for invalid in [generated.privateSeedBase64, generated.openSSHPublicLine,
                        "-----BEGIN OPENSSH PRIVATE KEY-----\ninvalid\n-----END OPENSSH PRIVATE KEY-----"] {
            XCTAssertThrowsError(try stores.connectSSHKey(label: "Invalid", privateKeyPEM: invalid))
            do {
                _ = try await GitHubCredentialService(session: session).testSSH(invalid)
                XCTFail("GitHub credentials must contain a complete key that the daemon can use with OpenSSH")
            } catch { XCTAssertEqual(error.localizedDescription, t("github.credential.invalidKey")) }
        }
        XCTAssertTrue(stores.gitHubAccounts().isEmpty)
    }

    func testTokenCheckSurfacesUnauthorizedSSOAndRepositoryFailures() async throws {
        let session = fixtureSession()
        for status in [401, 403] {
            CredentialHTTPFixture.respond = { request in
                if status == 403, request.url?.path == "/user" {
                    return (200, [:], Data(#"{"login":"octocat"}"#.utf8))
                }
                return (status, status == 403 ? ["X-GitHub-SSO": "required"] : [:], Data(#"{"message":"Access denied"}"#.utf8))
            }
            do {
                _ = try await GitHubCredentialService(session: session).testToken("fixture")
                XCTFail("A failed repository endpoint must not become a successful token check")
            } catch {
                XCTAssertEqual(error.localizedDescription, t(status == 401 ? "github.credential.tokenRejected" : "github.credential.authorizeSSO"))
            }
        }
    }

    func testSetupLinksPreselectRepositoryAccessAndOptionalWorkflowAccess() throws {
        for classic in [false, true] {
            for workflows in [false, true] {
                let url = GitHubCredentialLinks.token(name: "Work & iOS", classic: classic, workflows: workflows)
                let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
                let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(parts.host, "github.com")
                if classic {
                    XCTAssertEqual(query["description"], "Work & iOS")
                    XCTAssertEqual(query["scopes"], workflows ? "repo,workflow" : "repo")
                } else {
                    XCTAssertEqual(query["name"], "Work & iOS")
                    XCTAssertEqual(query["contents"], "write")
                    XCTAssertEqual(query["pull_requests"], "write")
                    XCTAssertEqual(query["workflows"], workflows ? "write" : nil)
                }
                XCTAssertFalse(url.absoluteString.contains("read:org"))
            }
        }
        let malformed = try JSONDecoder().decode(GitHubSSHMetadata.self, from: Data(#"{"ssh_key_fingerprints":{"SHA256_ED25519":"invalid","MD5_RSA":"anything"}}"#.utf8))
        XCTAssertTrue(malformed.fingerprints.isEmpty, "An absent GitHub pin must never fall back to trusting any host")
    }

    func testCredentialFormsAndDetailsUseNativeRowsAndHideSavedSecrets() async throws {
        let stores = try fixtureStores()
        let account = try stores.connectToken(login: "octocat", name: "Octo Cat", token: "NEVER-RENDER-THIS-SECRET", label: "Work repositories")
        defer { stores.removeGitHubAccount(account.id) }
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let details = try await render(NavigationStack { GitHubConnectionScreen(account: account) }, stores: stores,
                                          name: "mindwire-github-details-\(suffix)", scheme: scheme)
            let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(details.rootViewController))).lowercased()
            XCTAssertTrue(text.contains("work repositories"), text)
            XCTAssertTrue(text.contains("octocat"), text)
            XCTAssertTrue(text.contains("test connection"), text)
            XCTAssertTrue(text.contains("edit"), text)
            XCTAssertFalse(text.contains("never-render"), "Saved tokens must remain masked until explicitly revealed")
            details.isHidden = true

            let editor = try await render(NavigationStack { GitHubCredentialEditor(mode: .token) { _ in } }, stores: stores,
                                         name: "mindwire-github-add-token-\(suffix)", scheme: scheme)
            let form = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(editor.rootViewController))).lowercased()
            XCTAssertTrue(form.contains("name"), form)
            XCTAssertTrue(form.contains("create token on github"), form)
            XCTAssertTrue(form.contains("test connection"), form)
            editor.isHidden = true
        }
        let ssh = try await render(NavigationStack { GitHubCredentialEditor(mode: .sshKey) { _ in } }, stores: stores,
                                   name: "mindwire-github-add-ssh")
        defer { ssh.isHidden = true }
        let keyForm = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(ssh.rootViewController))).lowercased()
        XCTAssertTrue(keyForm.contains("public key"), keyForm)
        XCTAssertTrue(keyForm.contains("add key on github"), keyForm)
        XCTAssertTrue(keyForm.contains("test connection"), keyForm)
        XCTAssertFalse(keyForm.contains("private key-----"))
    }

    func testAddOptionsMakeTokensAndSSHKeysVisibleWithoutExpansion() async throws {
        let stores = try fixtureStores()
        let window = try await render(GitHubConnectScreen { _ in }, stores: stores, name: "mindwire-github-methods")
        defer { window.isHidden = true }
        let text = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(try XCTUnwrap(window.rootViewController))).lowercased()
        XCTAssertTrue(text.contains("personal access token"), text)
        XCTAssertTrue(text.contains("ssh key"), text)
        XCTAssertFalse(text.contains("other ways"), text)
    }

    func testConnectionListReflectsRenamesAndRemovalsWithoutReopening() async throws {
        let stores = try fixtureStores()
        let work = try stores.connectToken(login: "octocat", name: "Octo", token: "work-fixture", label: "Work repositories", checked: true)
        let personal = try stores.connectToken(login: "octocat", name: "Octo", token: "personal-fixture", label: "Personal")
        defer { stores.removeGitHubAccount(work.id); stores.removeGitHubAccount(personal.id) }
        let window = try await render(NavigationStack { GitHubAccountsScreen() }, stores: stores, name: "mindwire-github-connections")
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController)
        let initial = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(initial.contains("Work repositories"), initial)
        XCTAssertTrue(initial.contains("Personal"), initial)
        try stores.renameGitHubAccount(work.id, label: "Client projects")
        stores.removeGitHubAccount(personal.id)
        try await Task.sleep(for: .milliseconds(250))
        let updated = try ChatFeedSnapshot.visibleText(in: ChatFeedSnapshot.image(host))
        XCTAssertTrue(updated.contains("Client projects"), updated)
        XCTAssertFalse(updated.contains("Work repositories"), updated)
        XCTAssertEqual(stores.gitHubAccounts().count, 1)
    }

    func testLiveGitHubSSHRejectsAnUnregisteredKey() async throws {
        guard ProcessInfo.processInfo.environment["MINDWIRE_LIVE_GITHUB"] == "1" else {
            throw XCTSkip("Opt-in live GitHub SSH handshake; uses a fresh, unregistered fixture key.")
        }
        do {
            _ = try await GitHubCredentialService().testSSH(key())
            XCTFail("GitHub cannot accept a fresh key that has never been registered")
        } catch {
            XCTAssertEqual(error.localizedDescription, t("github.credential.keyRejected"),
                           "The real HTTPS metadata, pinned host-key handshake and authentication must complete")
        }
    }

    private func render<V: View>(_ view: V, stores: Stores, name: String, scheme: ColorScheme = .dark) async throws -> UIWindow {
        let host = UIHostingController(rootView: view.environment(\.stores, stores).tint(Palette.accent)
            .labelIconToTitleSpacing(Spacing.md).preferredColorScheme(scheme))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(650))
        let image = ChatFeedSnapshot.image(host)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        return window
    }

    private func fixtureStores() throws -> Stores {
        let suite = "github-credentials-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    private func fixtureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CredentialHTTPFixture.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel(); CredentialHTTPFixture.respond = nil }
        return session
    }

    private func key() throws -> String {
        let generated = SSHKey.generate(comment: "fixture")
        return try XCTUnwrap(SSHKey.openSSHPrivateKeyPEM(fromSeedBase64: generated.privateSeedBase64, comment: "fixture"))
    }

    private static func report(login: String = "octocat") -> GitHubCredentialReport {
        .init(mode: .token, user: .init(login: login, name: "Octo", avatarUrl: nil))
    }
}

@MainActor
private final class CredentialVerifierFixture {
    var calls = 0
    var didStart: (() -> Void)?
    var continuation: CheckedContinuation<GitHubCredentialReport, Error>?
    func verify(_ mode: GitHubAuthMode, _ secret: String) async throws -> GitHubCredentialReport {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0; didStart?() }
    }
    func finish(_ report: GitHubCredentialReport) { continuation?.resume(returning: report); continuation = nil }
}

private final class CredentialHTTPFixture: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.respond!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
