import XCTest
@testable import Mindwire

@MainActor
final class ReleaseCatalogTests: XCTestCase {
    private let catalog = DaemonCatalog(version: "1.2.3", agents: [
        AgentDescriptor(id: .codex, name: "Codex CLI", tagline: "Coding agent")
    ])

    private func defaults() throws -> UserDefaults {
        let suite = "MindwireTests.release-catalog.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testFreshWorkspaceListsAgentsWithoutConnectingToIt() async throws {
        let expected = DaemonCatalog(version: catalog.version, agents: [
            AgentDescriptor(id: .claudeCode, name: "Claude Code", tagline: "Coding agent")
        ] + catalog.agents)
        let source = ReleaseCatalog(defaults: try defaults(), fetch: { expected })
        // There is no workspace with this ID. Listing supported agents must not resolve it,
        // create a daemon token, contact a backend, or install anything on the workspace.
        let model = NewAgentModel(workspaceId: "unprovisioned-workspace", agentType: .codex, releaseCatalog: source)
        await model.loadCatalog()
        XCTAssertEqual(model.catalog, expected.agents)
        XCTAssertEqual(model.agentType, .codex)
        XCTAssertNil(model.catalogError)
        XCTAssertFalse(model.loadingCatalog)
        XCTAssertNil(model.createdAgent, "Choosing an agent type must wait for the explicit Create action")
    }

    func testCatalogIsAvailableBeforeChoosingAWorkspaceAndSurvivesRelaunch() async throws {
        let defaults = try defaults()
        let expected = catalog
        let source = ReleaseCatalog(defaults: defaults, fetch: { expected })
        _ = try await source.load()
        let reloaded = ReleaseCatalog(defaults: defaults, fetch: {
            XCTFail("A fresh persisted catalog should not require a network request")
            throw URLError(.notConnectedToInternet)
        })
        let model = NewAgentModel(releaseCatalog: reloaded)
        await model.loadCatalog()
        XCTAssertNil(model.workspaceId)
        XCTAssertEqual(model.catalog, expected.agents)
        XCTAssertFalse(model.loadingCatalog)
    }

    func testStaleCatalogRemainsUsableWhileRefreshIsPendingAndOffline() async throws {
        let defaults = try defaults()
        let expected = catalog
        _ = try await ReleaseCatalog(defaults: defaults, fetch: { expected }).load()
        let gate = CatalogFetchGate()
        let source = ReleaseCatalog(defaults: defaults, maxAge: 0, fetch: { try await gate.fetch() })
        let model = NewAgentModel(workspaceId: "fresh-workspace", releaseCatalog: source)
        let loading = Task { await model.loadCatalog() }
        await gate.waitUntilStarted()
        XCTAssertEqual(model.catalog, expected.agents)
        XCTAssertFalse(model.loadingCatalog)
        await gate.finish(.failure(URLError(.notConnectedToInternet)))
        await loading.value
        XCTAssertEqual(model.catalog, expected.agents)
        XCTAssertNil(model.catalogError)
    }

    func testConcurrentPickersShareOneCatalogFetch() async throws {
        let gate = CatalogFetchGate()
        let source = ReleaseCatalog(defaults: try defaults(), fetch: { try await gate.fetch() })
        async let first = source.load()
        async let second = source.load()
        await gate.waitUntilStarted()
        await gate.finish(.success(catalog))
        let results = try await [first, second]
        XCTAssertEqual(results, [catalog, catalog])
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
    }

    func testFailedFirstFetchCanBeRetried() async throws {
        let gate = CatalogFetchGate()
        let source = ReleaseCatalog(defaults: try defaults(), fetch: { try await gate.fetch() })
        let model = NewAgentModel(releaseCatalog: source)
        let loading = Task { await model.loadCatalog() }
        await gate.waitUntilStarted()
        await gate.finish(.failure(URLError(.notConnectedToInternet)))
        await loading.value
        XCTAssertTrue(model.catalog.isEmpty)
        XCTAssertNotNil(model.catalogError)
        XCTAssertFalse(model.loadingCatalog)

        let retry = Task { await model.loadCatalog() }
        await gate.waitUntilStarted()
        await gate.finish(.success(catalog))
        await retry.value
        XCTAssertEqual(model.catalog, catalog.agents)
        XCTAssertNil(model.catalogError)
    }

    func testExplicitUpdateCannotUseAStaleCatalogWhenRefreshFails() async throws {
        let defaults = try defaults(), expected = catalog
        _ = try await ReleaseCatalog(defaults: defaults, fetch: { expected }).load()
        let source = ReleaseCatalog(defaults: defaults, fetch: { throw URLError(.notConnectedToInternet) })
        do {
            _ = try await source.load(maxAge: 0, allowStale: false)
            XCTFail("An update must not silently fall back to an old release")
        } catch {}
        let cached = try await source.load(maxAge: 0)
        XCTAssertEqual(cached, expected, "Offline pickers retain their cache")
    }

    func testReleaseCatalogDownloadsOnlyTheMatchingMetadataAsset() async throws {
        let expected = catalog
        let session = session { request in
            switch request.url?.absoluteString {
            case AppConstants.mindwireReleaseAPI:
                return Data(#"{"tag_name":"v1.2.3"}"#.utf8)
            case "https://github.com/oblien/mindwire/releases/download/v1.2.3/catalog-v1.2.3.json":
                return try JSONEncoder().encode(expected)
            default:
                XCTFail("Unexpected request while listing agents: \(request.url?.absoluteString ?? "nil")")
                throw URLError(.unsupportedURL)
            }
        }
        defer { session.invalidateAndCancel() }
        let fetched = try await DaemonRelease.latestCatalog(session: session)
        XCTAssertEqual(fetched, expected)
    }

    func testReleaseCatalogRejectsMismatchedOrEmptyMetadata() async throws {
        for invalid in [DaemonCatalog(version: "1.2.2", agents: catalog.agents),
                        DaemonCatalog(version: "1.2.3", agents: [])] {
            let session = session { request in
                if request.url?.absoluteString == AppConstants.mindwireReleaseAPI {
                    return Data(#"{"tag_name":"v1.2.3"}"#.utf8)
                }
                return try JSONEncoder().encode(invalid)
            }
            defer { session.invalidateAndCancel() }
            do {
                _ = try await DaemonRelease.latestCatalog(session: session)
                XCTFail("Invalid release metadata must not populate the picker")
            } catch {}
        }
    }

    private func session(_ response: @escaping (URLRequest) throws -> Data) -> URLSession {
        ReleaseCatalogURLProtocol.response = response
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseCatalogURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor CatalogFetchGate {
    private var pending: [CheckedContinuation<DaemonCatalog, Error>] = []
    private var started: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func fetch() async throws -> DaemonCatalog {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if !pending.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: Result<DaemonCatalog, Error>) {
        for continuation in pending { continuation.resume(with: result) }
        pending = []
    }
}

private final class ReleaseCatalogURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Data)?
    static var response: ((URLRequest) throws -> Data)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let response = Self.response, let url = request.url else { throw URLError(.badURL) }
            let data = try response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
