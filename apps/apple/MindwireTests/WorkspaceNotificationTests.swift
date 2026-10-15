import XCTest
import OblienKit
@testable import Mindwire

final class WorkspaceNotificationTests: XCTestCase {
    private static let cloudScope = WorkspaceNotificationScope(workspaceID: "workspace", runtime: .cloud(workspaceId: "workspace"))!

    func testComputerAndSandboxUseGenericSendCredentialsWithTheirOwnChannel() throws {
        let computer = try XCTUnwrap(WorkspaceNotificationScope(workspaceID: "my-mac", runtime: .server(serverId: "paired-mac")))
        let sandbox = try XCTUnwrap(WorkspaceNotificationScope(workspaceID: "my-container", runtime: .container(serverId: "ssh-host", sandbox: .init(id: "box", version: "0.1.43"))))
        XCTAssertNil(computer.cloudWorkspaceID)
        XCTAssertNil(sandbox.cloudWorkspaceID)
        XCTAssertEqual(computer.workspaceID, "my-mac")
        XCTAssertEqual(sandbox.workspaceID, "my-container")
        XCTAssertEqual(Self.cloudScope.cloudWorkspaceID, "workspace")
        XCTAssertNil(WorkspaceNotificationScope(workspaceID: "pending", runtime: .cloud))
        XCTAssertNil(WorkspaceNotificationScope(workspaceID: "", runtime: .server(serverId: "host")))
    }

    func testRemoteAgentsShareMintAndCannotReuseACloudCredential() async throws {
        let fixture = WorkspaceTokenFixture(), cache = NotificationCredentialCache()
        let tokens = makeTokens(fixture, cache)
        let remote = try XCTUnwrap(WorkspaceNotificationScope(workspaceID: "workspace", runtime: .server(serverId: "mac")))
        let cloud = await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone")
        async let first = tokens.token(scope: remote, accountID: 1, deviceID: "phone")
        async let second = tokens.token(scope: remote, accountID: 1, deviceID: "phone")
        let (a, b) = await (first, second)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, cloud)
        let reused = await tokens.token(scope: remote, accountID: 1, deviceID: "phone")
        XCTAssertEqual(reused, a)
        let scopes = await fixture.scopes
        XCTAssertEqual(scopes, [Self.cloudScope, remote])
        let listed = await fixture.listed
        XCTAssertEqual(listed.count, 1)
        XCTAssertNil(listed[0], "A local workspace ID must not be sent as an Oblien workspace filter")
    }

    func testDaemonProvisioningVerifiesPushFormatAndCredentialPresence() async throws {
        let channel = NotificationConfigChannel(format: "push", hasToken: true)
        try await ExecDaemonTransport(channel: channel, agentType: "codex")
            .setNotifyConfig(url: "https://relay.example/send", channel: "workspace", token: "secret")
        let saved = await channel.saved
        XCTAssertEqual(saved?["format"], "push")
        XCTAssertEqual(saved?["token"], "secret")
        for invalid in [NotificationConfigChannel(format: nil, hasToken: nil),
                        NotificationConfigChannel(format: "push", hasToken: false)] {
            do {
                try await ExecDaemonTransport(channel: invalid, agentType: "codex")
                    .setNotifyConfig(url: "https://relay.example/send", channel: "workspace", token: "secret")
                XCTFail("Incomplete daemon notification setup must not report success")
            } catch {
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("update"))
            }
        }
    }

    func testConcurrentAgentsShareOneMintAndReuseValidatedCredential() async throws {
        let fixture = WorkspaceTokenFixture(), cache = NotificationCredentialCache()
        let tokens = makeTokens(fixture, cache)
        let values = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<6 { group.addTask { await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone") } }
            var values: [String?] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(Set(values.compactMap { $0 }).count, 1)
        XCTAssertFalse(values.contains { $0 == nil })
        let again = await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone")
        XCTAssertEqual(again, values.first!)
        let minted = await fixture.tags
        XCTAssertEqual(minted.count, 1)
    }

    func testRevokedCredentialIsReplacedBeforeConfiguringDaemon() async {
        let fixture = WorkspaceTokenFixture(), cache = NotificationCredentialCache()
        let tokens = makeTokens(fixture, cache)
        let old = await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone")
        await fixture.revoke()
        let refreshed = await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone")
        XCTAssertNotNil(refreshed)
        XCTAssertNotEqual(old, refreshed)
        let count = await fixture.tags.count
        XCTAssertEqual(count, 2)
    }

    func testAccountAndDeviceCredentialsAreIsolated() async {
        let fixture = WorkspaceTokenFixture(), cache = NotificationCredentialCache()
        let tokens = makeTokens(fixture, cache)
        let a = await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone-a")
        let b = await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone-b")
        let c = await tokens.token(scope: Self.cloudScope, accountID: 2, deviceID: "phone-a")
        XCTAssertEqual(Set([a, b, c].compactMap { $0 }).count, 3)
        let tags = await fixture.tags
        XCTAssertNotEqual(tags[0], tags[1], "Another phone must not rotate this phone's send credential")
        XCTAssertEqual(cache.count, 3)
    }

    func testFailedValidationRetriesWithoutReinstallingDaemon() async {
        let fixture = WorkspaceTokenFixture(), cache = NotificationCredentialCache()
        let tokens = makeTokens(fixture, cache)
        let initial = await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone")
        await fixture.setOffline(true)
        let offline = await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone")
        XCTAssertNil(offline)
        await fixture.setOffline(false)
        let recovered = await tokens.token(scope: Self.cloudScope, accountID: 1, deviceID: "phone")
        XCTAssertEqual(initial, recovered)
        let count = await fixture.tags.count
        XCTAssertEqual(count, 1)
    }

    private func makeTokens(_ fixture: WorkspaceTokenFixture, _ cache: NotificationCredentialCache) -> WorkspaceNotificationTokens {
        WorkspaceNotificationTokens(read: { cache.read($0) }, write: { cache.write($0, $1) },
                                    list: { try await fixture.list($0) },
                                    mint: { scope, tag in try await fixture.mint(scope, tag) })
    }
}

private actor NotificationConfigChannel: DaemonChannel {
    nonisolated let label = "notification-test"
    let format: String?
    let hasToken: Bool?
    var saved: [String: String]?
    init(format: String?, hasToken: Bool?) { self.format = format; self.hasToken = hasToken }
    func perform(method: String, path: String, jsonBody: Data?) async throws -> (status: Int, body: String) {
        XCTAssertTrue(path.hasPrefix("/notify/config"))
        if method == "PUT" {
            saved = try JSONDecoder().decode([String: String].self, from: jsonBody!)
            return (204, "")
        }
        var result: [String: Any] = ["configured": true, "url": "https://relay.example/send", "channel": "workspace"]
        result["format"] = format
        result["hasToken"] = hasToken
        return (200, String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
    }
}

private final class NotificationCredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var count: Int { lock.withLock { values.count } }
    func read(_ key: String) -> String? { lock.withLock { values[key] } }
    func write(_ key: String, _ value: String) { lock.withLock { values[key] = value } }
}

private actor WorkspaceTokenFixture {
    var tags: [String] = []
    var scopes: [WorkspaceNotificationScope] = []
    var listed: [String?] = []
    var values: [WorkspaceSendToken] = []
    var offline = false
    func setOffline(_ value: Bool) { offline = value }
    func list(_ workspace: String?) throws -> [WorkspaceSendToken] {
        listed.append(workspace)
        if offline { throw APIError.transport("offline") }
        return values
    }
    func mint(_ scope: WorkspaceNotificationScope, _ tag: String) async throws -> WorkspaceSendToken {
        tags.append(tag)
        scopes.append(scope)
        let id = tags.count
        try await Task.sleep(for: .milliseconds(20))
        let bytes = try JSONSerialization.data(withJSONObject: ["id": id, "tag": tag, "status": "active",
                                                               "tokenPrefix": "send-\(id)-", "token": "send-\(id)-secret"])
        let token = try JSONDecoder().decode(WorkspaceSendToken.self, from: bytes)
        values.append(token)
        return token
    }
    func revoke() { for i in values.indices { values[i].status = "revoked" } }
}
