import XCTest
import Network
import OblienKit
@testable import Mindwire

@MainActor
final class WorkspaceSignInTests: XCTestCase {
    func testCloudManagementUsesMindwireAndRuntimeUsesOblienGateway() {
        XCTAssertEqual(MindwireCloud.client.config.baseURL.absoluteString, AppConstants.mindwireServicesBase + "/api/cloud/provider")
        XCTAssertEqual(MindwireCloud.client.config.runtimeURL.absoluteString, "https://workspace.oblien.com")
        XCTAssertNotEqual(MindwireCloud.client.config.baseURL.host, MindwireCloud.client.config.runtimeURL.host)
    }

    func testCloudAccountAndComputerCredentialsDoNotFollowRedirects() async throws {
        let server = try CloudAccountProbe()
        let origin = try await server.start()
        defer { server.close() }
        var account = URLRequest(url: origin.appendingPathComponent("account"))
        account.setValue("Bearer fixture-account-session", forHTTPHeaderField: "Authorization")
        let (_, accountResponse) = try await MindwireAPI.httpSession.data(for: account)
        XCTAssertEqual((accountResponse as? HTTPURLResponse)?.statusCode, 302)
        let channel = URLSessionDaemonChannel(session: MindwireAPI.httpSession) { _, _, _, _ in
            var request = URLRequest(url: origin.appendingPathComponent("daemon"))
            request.setValue("Bearer fixture-computer-jwt", forHTTPHeaderField: "Authorization")
            request.setValue("fixture-daemon-token", forHTTPHeaderField: "X-Mindwire-Token")
            return request
        }
        let response = try await channel.perform(method: "GET", path: "/", jsonBody: nil)
        XCTAssertEqual(response.status, 302)
        let requests = server.requests
        XCTAssertEqual(requests.count, 2, "No redirect destination should receive credentials")
        XCTAssertTrue(requests[0].contains("Bearer fixture-account-session"))
        XCTAssertTrue(requests[1].contains("Bearer fixture-computer-jwt"))
        XCTAssertFalse(requests[1].contains("fixture-account-session"))
        XCTAssertTrue(requests[1].contains("fixture-daemon-token"))
    }

    func testSDKRuntimeUsesOnlyTheOwnedComputerCredential() async throws {
        let server = try CloudAccountProbe(redirects: false)
        let origin = try await server.start()
        defer { server.close() }
        let client = OblienClient(.init(auth: .scopedToken("fixture-account-session"), baseURL: origin,
            runtimeURL: origin, maxRetries: 0))
        let runtime = try await client.workspace("owned").runtime()
        let healthy = try await runtime.health()
        XCTAssertTrue(healthy)
        let requests = server.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[0].contains("Bearer fixture-account-session"))
        XCTAssertTrue(requests[1].contains("Bearer fixture-account-session"))
        XCTAssertTrue(requests[2].hasPrefix("GET /health "))
        XCTAssertTrue(requests[2].contains("Bearer fixture-computer-jwt"))
        XCTAssertFalse(requests[2].contains("fixture-account-session"))
    }

    private let signedIn = AuthStatus(authenticated: true, user: AuthUser(id: "42", name: "Test owner"))

    private func stores() throws -> Stores {
        let suite = "workspace-sign-in-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let stores = Stores(defaults: defaults)
        let remote = WorkspaceRemoteFixture()
        remote.prepareError = URLError(.notConnectedToInternet)
        stores.workspaceData = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, resolveWorkspace: { _ in nil })
        return stores
    }

    private func cloudWorkspace() throws -> OblienKit.Workspace {
        try JSONDecoder().decode(OblienKit.Workspace.self,
            from: Data(#"{"id":"cloud-workspace","name":"My Mac","created_at":"2026-09-17T00:00:00Z"}"#.utf8))
    }

    func testColdInventoryWaitsForSharedSignInBeforeCachingItsFirstList() async throws {
        let stores = try stores()
        var authRequests = 0
        var finishAuth: CheckedContinuation<AuthStatus, Error>?
        let auth = MindwireAuth {
            authRequests += 1
            return try await withCheckedThrowingContinuation { finishAuth = $0 }
        }
        let workspace = try cloudWorkspace()
        var listRequests = 0
        let adapter = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) {
            listRequests += 1; return [workspace]
        }
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        let launchAuth = Task { await auth.refresh() }
        for _ in 0..<100 where finishAuth == nil { await Task.yield() }
        XCTAssertNotNil(finishAuth)
        defer { finishAuth?.resume(throwing: CancellationError()) }
        let inventory = Task { await repository.refreshIfNeeded() }
        for _ in 0..<100 where !repository.isRefreshing { await Task.yield() }
        XCTAssertTrue(repository.isRefreshing)
        XCTAssertFalse(repository.hasRefreshed, "Unresolved sign-in must not become a fresh empty inventory")
        XCTAssertEqual(listRequests, 0)
        XCTAssertEqual(authRequests, 1)
        finishAuth?.resume(returning: signedIn); finishAuth = nil
        await launchAuth.value
        await inventory.value
        XCTAssertEqual(repository.all.map(\.id), [workspace.id])
        XCTAssertNil(repository.refreshError)
        await repository.refreshIfNeeded()
        XCTAssertEqual(listRequests, 1, "A real successful list remains cached across navigation")
        XCTAssertEqual(authRequests, 1)
    }

    func testFailedInitialSignInIsAnInventoryErrorAndRetryChecksAgain() async throws {
        let stores = try stores()
        var authRequests = 0
        let status = signedIn
        let auth = MindwireAuth {
            authRequests += 1
            if authRequests == 1 { throw URLError(.notConnectedToInternet) }
            return status
        }
        let workspace = try cloudWorkspace()
        var listRequests = 0
        let adapter = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) {
            listRequests += 1; return [workspace]
        }
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        await repository.refresh()
        XCTAssertNotNil(repository.refreshError)
        XCTAssertTrue(repository.all.isEmpty)
        XCTAssertEqual(listRequests, 0)
        await repository.refresh()
        XCTAssertNil(repository.refreshError)
        XCTAssertEqual(repository.all.map(\.id), [workspace.id])
        XCTAssertEqual(authRequests, 2, "A failed request must not cache a signed-out session")
        XCTAssertEqual(listRequests, 1)
    }

    func testTransientAuthRefreshDoesNotDiscardConfirmedAccountOrWorkspaceList() async throws {
        let stores = try stores()
        var offline = false
        let status = signedIn
        let auth = MindwireAuth {
            if offline { throw URLError(.networkConnectionLost) }
            return status
        }
        let workspace = try cloudWorkspace()
        let adapter = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) { [workspace] }
        try await adapter.refresh()
        offline = true
        await auth.refresh()
        XCTAssertTrue(auth.authenticated)
        XCTAssertEqual(auth.user?.id, "42")
        XCTAssertEqual(adapter.current().map(\.id), [workspace.id])
        let available = await auth.ensure()
        XCTAssertTrue(available)
    }

    func testWorkspaceResponseFromPreviousAccountIsNotPublished() async throws {
        let stores = try stores()
        var status = signedIn
        let auth = MindwireAuth { status }
        let workspace = try cloudWorkspace()
        var finishList: CheckedContinuation<[OblienKit.Workspace], Never>?
        let adapter = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) {
            await withCheckedContinuation { finishList = $0 }
        }
        let request = Task { try await adapter.refresh() }
        for _ in 0..<100 where finishList == nil { await Task.yield() }
        XCTAssertNotNil(finishList)
        defer { finishList?.resume(returning: []) }
        status = AuthStatus(authenticated: true, user: AuthUser(id: "84", name: "Another owner"))
        await auth.refresh()
        finishList?.resume(returning: [workspace]); finishList = nil
        do { try await request.value; XCTFail("The old account's response must be discarded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(adapter.current().isEmpty)
        XCTAssertNil(stores.defaults.data(forKey: StorageKey.cloudWorkspaceCache))
    }

    func testSignedOutCloudReferencesRequireLoginWhileLocalProjectsStayAvailable() async throws {
        let stores = try stores()
        let local = stores.createWorkspace(name: "My server", runtime: .server(serverId: "local-server"))
        let localProject = stores.createProject(.init(name: "Local project", workspaceId: local.id, path: "/local"))
        let cloudProject = stores.createProject(.init(name: "Cloud project", workspaceId: "cloud-workspace", path: "/cloud"))
        let chat = stores.createChat(agentId: "cloud-agent", projectId: cloudProject.id)
        var authRequests = 0
        let auth = MindwireAuth { authRequests += 1; return AuthStatus(authenticated: false) }
        var listRequests = 0
        let cloud = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) {
            listRequests += 1; return []
        }
        let repository = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores), cloud])

        XCTAssertFalse(repository.requiresSignIn, "An unresolved initial session is not a confirmed sign-out")
        XCTAssertNotNil(repository.get(local.id), "Local records do not wait for cloud auth")
        await repository.refresh()
        XCTAssertTrue(repository.requiresSignIn(for: cloudProject.workspaceId))
        XCTAssertFalse(repository.requiresSignIn(for: local.id))
        XCTAssertEqual(repository.all.map(\.id), [local.id])
        XCTAssertNil(repository.refreshError, "Signing out is not a workspace failure")
        XCTAssertEqual(listRequests, 0, "Signed-out users must not call the cloud inventory")
        XCTAssertEqual(authRequests, 1)
        XCTAssertNotNil(stores.projects.get(localProject.id))
        XCTAssertNotNil(stores.projects.get(cloudProject.id))
        XCTAssertNotNil(stores.chats.get(chat.id))

        let reopened = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores),
            CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) {
                XCTFail("No inventory request is needed while signed out"); return []
            }])
        await reopened.refresh()
        XCTAssertTrue(reopened.requiresSignIn(for: cloudProject.workspaceId), "Cloud recovery must survive a fresh workspace cache")
        XCTAssertFalse(reopened.requiresSignIn(for: local.id))
        XCTAssertNotNil(stores.projects.get(cloudProject.id))
    }

    func testSignOutHidesCachedCloudWorkspaceImmediatelyAndSignInRestoresIt() async throws {
        let stores = try stores()
        let local = stores.createWorkspace(name: "My server", runtime: .server(serverId: "local-server"))
        let project = stores.createProject(.init(name: "Cloud project", workspaceId: "cloud-workspace", path: "/cloud"))
        var status = signedIn
        let auth = MindwireAuth { status }
        let workspace = try cloudWorkspace()
        var listRequests = 0
        let cloud = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) {
            listRequests += 1; return [workspace]
        }
        let repository = WorkspaceRepository(stores: stores, adapters: [LocalWorkspaceAdapter(stores: stores), cloud])
        await repository.refresh()
        XCTAssertNotNil(repository.get(workspace.id))

        status = AuthStatus(authenticated: false)
        await auth.refresh()
        XCTAssertTrue(cloud.current().isEmpty, "A confirmed sign-out immediately hides cached cloud records")
        XCTAssertNil(repository.get(workspace.id), "Cached cloud tools must stop being available immediately on sign-out")
        XCTAssertTrue(repository.requiresSignIn(for: workspace.id))
        XCTAssertNotNil(repository.get(local.id))
        await repository.refresh()
        XCTAssertTrue(cloud.current().isEmpty)
        XCTAssertNil(stores.defaults.data(forKey: StorageKey.cloudWorkspaceCache))
        XCTAssertNotNil(stores.projects.get(project.id))
        XCTAssertEqual(listRequests, 1)

        status = signedIn
        await auth.refresh()
        await repository.refresh()
        XCTAssertNotNil(repository.get(workspace.id))
        XCTAssertFalse(repository.requiresSignIn(for: workspace.id))
        XCTAssertNotNil(repository.get(local.id))
        XCTAssertNotNil(stores.projects.get(project.id))
        XCTAssertEqual(listRequests, 2)
    }

    func testRelaunchRestoresWorkspaceBeforeAuthAndKeepsItDuringOfflineRevalidation() async throws {
        let stores = try stores(), workspace = try cloudWorkspace(), status = signedIn
        let first = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults,
            sessionToken: { "fixture-session" }) { [workspace] }
        try await first.refresh()
        let saved = try XCTUnwrap(stores.defaults.data(forKey: StorageKey.cloudWorkspaceCache))
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("fixture-session"),
                       "The display cache must not contain the session credential")
        stores.createProject(.init(name: "Website", workspaceId: workspace.id, path: "/projects/site"))

        var finishAuth: CheckedContinuation<AuthStatus, Error>?
        let auth = MindwireAuth { try await withCheckedThrowingContinuation { finishAuth = $0 } }
        let restored = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) {
            throw URLError(.notConnectedToInternet)
        }
        let repository = WorkspaceRepository(stores: stores, adapters: [restored])
        XCTAssertEqual(repository.get(workspace.id)?.name, "My Mac", "The first render must not wait for a request")
        XCTAssertFalse(repository.hasRefreshed, "Restored metadata is not a completed live check")
        XCTAssertFalse(repository.requiresSignIn)

        let refresh = Task { await repository.refreshIfNeeded() }
        for _ in 0..<100 where finishAuth == nil { await Task.yield() }
        XCTAssertNotNil(finishAuth)
        defer { finishAuth?.resume(throwing: CancellationError()) }
        XCTAssertFalse(repository.isRefreshing, "A warm inventory revalidates without replacing ready rows")
        XCTAssertEqual(repository.get(workspace.id)?.name, "My Mac")
        finishAuth?.resume(throwing: URLError(.notConnectedToInternet)); finishAuth = nil
        await refresh.value
        XCTAssertNotNil(repository.refreshError)
        XCTAssertEqual(repository.get(workspace.id)?.name, "My Mac", "A failed auth check is not a sign-out")

        let retry = Task { await repository.refresh() }
        for _ in 0..<100 where finishAuth == nil { await Task.yield() }
        XCTAssertNotNil(finishAuth)
        finishAuth?.resume(returning: status); finishAuth = nil
        await retry.value
        XCTAssertNotNil(repository.refreshError)
        XCTAssertEqual(repository.get(workspace.id)?.name, "My Mac", "A failed list must keep the saved snapshot")
        XCTAssertEqual(stores.defaults.data(forKey: StorageKey.cloudWorkspaceCache), saved)
    }

    func testSavedInventoryDoesNotCrossSessionOrAccountBoundaries() async throws {
        let stores = try stores(), workspace = try cloudWorkspace(), status = signedIn
        let auth = MindwireAuth { status }
        let first = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) { [workspace] }
        try await first.refresh()

        for token: String? in [nil, "another-session"] {
            let cold = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults, sessionToken: { token }) {
                XCTFail("Reading a cache must not make a network request"); return []
            }
            XCTAssertTrue(cold.current().isEmpty)
        }
        let otherAccount = MindwireAuth { AuthStatus(authenticated: true, user: AuthUser(id: "84", name: "Another owner")) }
        let restored = CloudWorkspaceAdapter(auth: otherAccount, defaults: stores.defaults, sessionToken: { "fixture-session" }) {
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(restored.current().map(\.id), [workspace.id])
        await otherAccount.refresh()
        XCTAssertTrue(restored.current().isEmpty, "Confirmed account changes must hide the old list immediately")
        do { try await restored.refresh(); XCTFail("Expected offline refresh") } catch {}
        XCTAssertNil(stores.defaults.data(forKey: StorageKey.cloudWorkspaceCache), "The old owner's snapshot cannot survive an account switch")
    }

    func testExplicitRefreshPersistsNewMetadataAndAnEmptyInventory() async throws {
        let stores = try stores(), status = signedIn
        var remote = [try cloudWorkspace()]
        let adapter = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults,
            sessionToken: { "fixture-session" }) { remote }
        let repository = WorkspaceRepository(stores: stores, adapters: [adapter])
        await repository.refresh()
        remote = [try JSONDecoder().decode(OblienKit.Workspace.self,
            from: Data(#"{"id":"cloud-workspace","name":"Renamed Mac","image":"macos"}"#.utf8))]
        await repository.refresh()
        let renamed = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults, sessionToken: { "fixture-session" }) { [] }
        XCTAssertEqual(renamed.current().first?.name, "Renamed Mac")
        XCTAssertEqual(renamed.current().first?.image, "macos")
        remote = []
        await repository.refresh()
        let empty = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults, sessionToken: { "fixture-session" }) { [] }
        XCTAssertTrue(empty.current().isEmpty, "Removed inventory must not return on the next launch")
        XCTAssertNotNil(stores.defaults.data(forKey: StorageKey.cloudWorkspaceCache))
    }

    func testDeletionUpdatesDiskAndAnOlderListCannotResurrectIt() async throws {
        let stores = try stores(), workspace = try cloudWorkspace(), status = signedIn
        var holdList = false
        var finishList: CheckedContinuation<[OblienKit.Workspace], Never>?
        let adapter = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults,
            sessionToken: { "fixture-session" }, removeWorkspace: { _ in }) {
            if holdList { return await withCheckedContinuation { finishList = $0 } }
            return [workspace]
        }
        try await adapter.refresh()
        holdList = true
        let oldRequest = Task { try await adapter.refresh() }
        for _ in 0..<100 where finishList == nil { await Task.yield() }
        XCTAssertNotNil(finishList)
        defer { finishList?.resume(returning: []) }
        try await adapter.delete(workspace.id)
        finishList?.resume(returning: [workspace]); finishList = nil
        try await oldRequest.value
        XCTAssertTrue(adapter.current().isEmpty)
        let reopened = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults, sessionToken: { "fixture-session" }) { [] }
        XCTAssertTrue(reopened.current().isEmpty)
    }

    func testAuthoritativeLookupAndNewWorkspaceAdoptionPersistAcrossLaunches() async throws {
        let stores = try stores(), workspace = try cloudWorkspace(), status = signedIn
        var deleted = false
        let auth = MindwireAuth { status }
        let adapter = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" },
            lookupWorkspace: { _ in
                if deleted { throw OblienError(kind: .server, status: 404, code: "not_found", message: "Not found", details: nil) }
                return workspace
            }) { [] }
        try await adapter.refresh()
        let missing = await adapter.confirmsDeletion(workspace.id)
        XCTAssertFalse(missing)
        let recovered = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) { [] }
        XCTAssertEqual(recovered.current().map(\.id), [workspace.id], "Lookup recovery must also repair the disk snapshot")
        deleted = true
        let confirmed = await adapter.confirmsDeletion(workspace.id)
        XCTAssertTrue(confirmed)
        let removed = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults, sessionToken: { "fixture-session" }) { [] }
        XCTAssertTrue(removed.current().isEmpty)
        let created = await removed.adopt(name: "Fresh workspace", runtime: .cloud(workspaceId: "new-workspace"), spec: nil)
        XCTAssertEqual(created?.id, "new-workspace")
        let adopted = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults, sessionToken: { "fixture-session" }) { [] }
        XCTAssertEqual(adopted.current().first?.name, "Fresh workspace", "A lagging list cannot lose a newly created workspace on restart")
    }

    func testDeletingRestoredWorkspaceWaitsForSessionVerification() async throws {
        let stores = try stores(), workspace = try cloudWorkspace(), status = signedIn
        let first = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults,
            sessionToken: { "fixture-session" }) { [workspace] }
        try await first.refresh()
        var finishAuth: CheckedContinuation<AuthStatus, Error>?
        var deleteCalls = 0
        let auth = MindwireAuth { try await withCheckedThrowingContinuation { finishAuth = $0 } }
        let restored = CloudWorkspaceAdapter(auth: auth, defaults: stores.defaults,
            sessionToken: { "fixture-session" }, removeWorkspace: { _ in deleteCalls += 1 }) { [] }
        XCTAssertEqual(restored.current().map(\.id), [workspace.id])
        let action = Task { try await restored.delete(workspace.id) }
        for _ in 0..<100 where finishAuth == nil { await Task.yield() }
        XCTAssertNotNil(finishAuth)
        defer { finishAuth?.resume(throwing: CancellationError()) }
        XCTAssertEqual(deleteCalls, 0)
        finishAuth?.resume(returning: status); finishAuth = nil
        try await action.value
        XCTAssertEqual(deleteCalls, 1)
        XCTAssertTrue(restored.current().isEmpty)
    }

    func testCorruptInventoryCacheFallsBackToALiveCheck() async throws {
        let stores = try stores(), workspace = try cloudWorkspace(), status = signedIn
        stores.defaults.set(Data("broken-cache".utf8), forKey: StorageKey.cloudWorkspaceCache)
        let adapter = CloudWorkspaceAdapter(auth: MindwireAuth { status }, defaults: stores.defaults, sessionToken: { "fixture-session" }) { [workspace] }
        XCTAssertTrue(adapter.current().isEmpty)
        try await adapter.refresh()
        XCTAssertEqual(adapter.current().map(\.id), [workspace.id])
    }
}

/// Real HTTP redirects exercise URLSession's delegate behavior (URLProtocol
/// fixtures do not reproduce the platform redirect callback).
private final class CloudAccountProbe: @unchecked Sendable {
    private let listener: NWListener
    private let redirects: Bool
    private let queue = DispatchQueue(label: "cloud-redirect-probe")
    private let lock = NSLock()
    private var recorded: [String] = []
    private var clients: [NWConnection] = []
    var requests: [String] { lock.withLock { recorded } }

    init(redirects: Bool = true) throws {
        self.redirects = redirects
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    if let port = self?.listener.port {
                        resumed = true
                        continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)")!)
                    }
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] client in
                guard let self else { client.cancel(); return }
                self.lock.withLock { self.clients.append(client) }
                client.start(queue: self.queue)
                self.read(client, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func read(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else { client.cancel(); return }
            let buffer = buffer + data
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                self.read(client, buffer: buffer); return
            }
            let request = String(decoding: buffer, as: UTF8.self)
            self.lock.withLock { self.recorded.append(request) }
            let response: String
            if self.redirects && !request.hasPrefix("GET /unexpected ") {
                response = "HTTP/1.1 302 Found\r\nLocation: /unexpected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            } else {
                let body: String
                if request.hasPrefix("GET /health ") { body = #"{"status":"ok"}"# }
                else if request.hasPrefix("GET /workspace/owned/runtime-api-access/token ") { body = #"{"token":"fixture-computer-jwt"}"# }
                else { body = #"{"enabled":true}"# }
                response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            }
            client.send(content: Data(response.utf8), completion: .contentProcessed { _ in client.cancel() })
        }
    }
    func close() { listener.cancel(); lock.withLock { clients.forEach { $0.cancel() } } }
}
