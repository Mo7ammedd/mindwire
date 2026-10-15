import XCTest
@testable import Mindwire

@MainActor
final class GitAuthorDefaultsTests: XCTestCase {
    func testDefaultReachesEveryWorkspaceAndKeepsSpecificOverrides() async throws {
        let stores = try stores()
        let first = AuthorRemoteFixture(), second = AuthorRemoteFixture()
        first.state.workspace = .init(name: "Workspace", email: "workspace@example.invalid")
        second.state.repository = .init(name: "Repository", email: "repo@example.invalid")
        let defaults = GitAuthorDefaults(stores: stores, knownIdentity: { "db-\($0)" }, connect: { id in
            .init(registryId: "db-\(id)", remote: id == "first" ? first : second)
        })
        let author = GitIdentity(name: "Shared Author", email: "shared@example.invalid")
        defaults.set(author)
        let a = await defaults.synchronize("first"), b = await defaults.synchronize("second")
        XCTAssertTrue(a && b)
        XCTAssertEqual(first.state.allWorkspaces, author)
        XCTAssertEqual(second.state.allWorkspaces, author)
        XCTAssertEqual(first.state.workspace?.name, "Workspace")
        XCTAssertEqual(second.state.repository?.name, "Repository")
        let again = await defaults.synchronize("first")
        XCTAssertTrue(again)
        XCTAssertEqual(first.saves.count, 1, "Navigation/reconciliation must not rewrite acknowledged defaults")
        XCTAssertFalse(defaults.isPending("first"))
    }

    func testOfflineAndNewWorkspacesReceivePersistedDefault() async throws {
        let stores = try stores()
        let remote = AuthorRemoteFixture()
        remote.offline = true
        let make: (String) async throws -> GitAuthorDefaults.Connection = { id in .init(registryId: "db-\(id)", remote: remote) }
        let defaults = GitAuthorDefaults(stores: stores, knownIdentity: { "db-\($0)" }, connect: make)
        let author = GitIdentity(name: "Shared", email: "shared@example.invalid")
        defaults.set(author)
        let offline = await defaults.synchronize("old")
        XCTAssertFalse(offline)
        XCTAssertTrue(defaults.isPending("old"))
        let resumed = GitAuthorDefaults(stores: stores, knownIdentity: { "db-\($0)" }, connect: make)
        XCTAssertEqual(resumed.preference?.identity, author)
        remote.offline = false
        let applied = await resumed.synchronize("old")
        XCTAssertTrue(applied)
        XCTAssertFalse(resumed.isPending("old"))
        XCTAssertTrue(resumed.isPending("new"))
        let future = await resumed.synchronize("new")
        XCTAssertTrue(future)
    }

    func testLostAcknowledgementRetainsRequestAndDoesNotOverwriteANewerDefault() async throws {
        let stores = try stores()
        let remote = AuthorRemoteFixture()
        remote.loseAcknowledgement = true
        let make: (String) async throws -> GitAuthorDefaults.Connection = { _ in .init(registryId: "database", remote: remote) }
        let defaults = GitAuthorDefaults(stores: stores, knownIdentity: { _ in "database" }, connect: make)
        defaults.set(.init(name: "Chosen", email: "chosen@example.invalid"))
        let first = await defaults.synchronize("workspace")
        XCTAssertFalse(first)
        let request = try XCTUnwrap(remote.saves.first)
        let resumed = GitAuthorDefaults(stores: stores, knownIdentity: { _ in "database" }, connect: make)
        let recovered = await resumed.synchronize("workspace")
        XCTAssertTrue(recovered)
        XCTAssertEqual(remote.saves.last, request)
        // A second pending delivery sees an intervening edit made by another client.
        remote.loseAcknowledgement = true
        resumed.set(.init(name: "Pending", email: "pending@example.invalid"))
        _ = await resumed.synchronize("workspace")
        remote.state.defaultRevision = "another-client"
        remote.state.allWorkspaces = .init(name: "Newer", email: "newer@example.invalid")
        let conflict = await resumed.synchronize("workspace")
        XCTAssertFalse(conflict)
        XCTAssertEqual(remote.state.allWorkspaces?.name, "Newer")
        XCTAssertNotNil(resumed.errors["workspace"])
        XCTAssertTrue(resumed.isPending("workspace"))
    }

    func testConcurrentSyncJoinsOneRequestAndNewerPreferenceStaysPending() async throws {
        let stores = try stores()
        let remote = AuthorRemoteFixture()
        remote.hold = true
        let defaults = GitAuthorDefaults(stores: stores, knownIdentity: { _ in "database" }, connect: { _ in
            .init(registryId: "database", remote: remote)
        })
        defaults.set(.init(name: "First", email: "first@example.invalid"))
        let first = Task { await defaults.synchronize("workspace") }
        for _ in 0..<100 where remote.waiting == nil { await Task.yield() }
        XCTAssertNotNil(remote.waiting)
        let joined = Task { await defaults.synchronize("workspace") }
        await Task.yield()
        defaults.set(.init(name: "Second", email: "second@example.invalid"))
        remote.release()
        _ = await first.value
        _ = await joined.value
        XCTAssertEqual(remote.saves.count, 1)
        XCTAssertTrue(defaults.isPending("workspace"))
        let latest = await defaults.synchronize("workspace")
        XCTAssertTrue(latest)
        XCTAssertEqual(remote.state.allWorkspaces?.name, "Second")
    }

    private func stores() throws -> Stores {
        let suite = "git-author-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }
}

@MainActor
private final class AuthorRemoteFixture: GitAuthorRemote {
    var state = GitAuthorSettings()
    var offline = false
    var loseAcknowledgement = false
    var hold = false
    var waiting: CheckedContinuation<Void, Never>?
    var saves: [GitAuthorUpdate] = []

    func load(_ context: GitAuthorContext?) async throws -> GitAuthorSettings {
        if offline { throw BackendError.message("Offline") }
        return state
    }

    func save(_ update: GitAuthorUpdate, context: GitAuthorContext?) async throws -> GitAuthorSettings {
        if offline { throw BackendError.message("Offline") }
        saves.append(update)
        if hold { await withCheckedContinuation { waiting = $0 } }
        if state.defaultRevision != update.requestId {
            guard state.defaultRevision == update.expectedRevision else { throw BackendError.message("Changed on another client") }
            state.defaultRevision = update.requestId ?? ""
            state.allWorkspaces = update.identity
        }
        state.effective = state.repository ?? state.workspace ?? state.allWorkspaces ?? GitIdentity()
        if loseAcknowledgement { loseAcknowledgement = false; throw BackendError.message("Lost response") }
        return state
    }

    func release() { hold = false; waiting?.resume(); waiting = nil }
}
