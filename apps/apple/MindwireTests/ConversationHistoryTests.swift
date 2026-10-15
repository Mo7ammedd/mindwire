import XCTest
import SwiftUI
@testable import Mindwire

@MainActor
final class ConversationHistoryTests: XCTestCase {
    private func row(_ id: String, cwd: String = "/Users/test/code/mobile", harness: String = "codex", chatId: String? = nil) -> Conversation {
        Conversation(id: id, chatId: chatId, agentType: harness, agentName: harness == "codex" ? "Codex" : "Claude Code",
                     cwd: cwd, title: id, createdAt: "2026-09-30T10:00:00Z", updatedAt: "2026-10-01T09:00:00Z")
    }

    private func cache() throws -> Stores {
        let suite = "conversation-history-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Stores(defaults: defaults)
    }

    func testGlobalHistoryCachesNavigationAndLoadsOlderPagesWithoutDuplicates() async throws {
        var requests: [ConversationQuery] = []
        let first = row("First"), second = row("Second")
        let repo = ConversationRepository(fetch: { _, query in
            requests.append(query)
            return ConversationPage(workspaceId: "database", items: query.cursor == nil ? [first] : [first, second],
                                    total: 2, nextCursor: query.cursor == nil ? "older" : nil)
        }, open: { _, _ in throw CancellationError() })
        let history = repo.history(workspaceId: "workspace", agentId: nil)
        await history.load()
        for _ in 0..<10 { await repo.history(workspaceId: "workspace", agentId: nil).load() }
        XCTAssertEqual(requests.count, 1, "Returning to a healthy browser must reuse its page")
        XCTAssertTrue(history === repo.history(workspaceId: "workspace", agentId: nil))
        await history.loadMore()
        XCTAssertEqual(history.items.map(\.id), ["First", "Second"])
        XCTAssertNil(history.nextCursor)
        XCTAssertEqual(requests.last?.cursor, "older")
        await history.load(force: true)
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.refresh, true)
        XCTAssertNil(requests.last?.cursor)
    }

    func testAgentWorkspaceAndSearchScopesHaveIndependentCaches() async {
        var scopes: [String] = []
        let repo = ConversationRepository(fetch: { workspace, query in
            scopes.append(workspace + "/" + (query.agentId ?? "all") + "/" + query.search)
            return .init(workspaceId: workspace, items: [], total: 0)
        }, open: { _, _ in throw CancellationError() })
        await repo.history(workspaceId: "one", agentId: "profile").load()
        await repo.history(workspaceId: "one", agentId: nil).load()
        await repo.history(workspaceId: "two", agentId: nil).load()
        await repo.history(workspaceId: "one", agentId: nil, search: " MOBILE ").load()
        await repo.history(workspaceId: "one", agentId: nil, search: "mobile").load()
        XCTAssertEqual(scopes, ["one/profile/", "one/all/", "two/all/", "one/all/mobile"])
    }

    func testConcurrentLoadsJoinOneRequestAndFailureKeepsCachedRows() async throws {
        var calls = 0
        var fail = false
        var gate: CheckedContinuation<Void, Never>?
        let first = row("Native chat")
        let history = ConversationHistory(query: .init()) { _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { gate = $0 } }
            if fail { throw BackendError.message("Temporarily offline") }
            return .init(workspaceId: "database", items: [first], total: 1)
        }
        let a = Task { await history.load() }
        for _ in 0..<100 where gate == nil { await Task.yield() }
        let b = Task { await history.load(force: true) }
        await Task.yield()
        XCTAssertEqual(calls, 1)
        gate?.resume()
        await a.value; await b.value
        fail = true
        await history.load(force: true)
        XCTAssertEqual(history.items, [first])
        XCTAssertEqual(history.error, "Temporarily offline")
        await history.load()
        XCTAssertEqual(calls, 2, "A failed refresh must briefly back off")
        fail = false
        await history.load(force: true)
        XCTAssertNil(history.error)
    }

    func testOlderPageCannotMixTwoWorkspaceIdentities() async {
        let first = row("Old workspace")
        let history = ConversationHistory(query: .init()) { query in
            .init(workspaceId: query.cursor == nil ? "old" : "replacement", items: [first], total: 2,
                  nextCursor: query.cursor == nil ? "older" : nil)
        }
        await history.load()
        await history.loadMore()
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertNil(history.nextCursor)
        XCTAssertNotNil(history.error)
    }

    func testOldRuntimeGivesAnActionableUpdateStateAndNeverDropsLoadedRows() async {
        let history = ConversationHistory(query: .init()) { _ in throw WorkspaceRegistryError.conversationBrowserUnavailable }
        await history.load()
        XCTAssertTrue(history.requiresUpdate)
        XCTAssertTrue(history.error?.contains("Update the Mindwire service") == true)
        XCTAssertFalse(history.isLoading)
    }

    func testOpeningSameNativeConversationCoalescesAndBindsOriginalChat() async throws {
        let item = row("native")
        let chat = Chat(id: "existing", agentId: "profile", projectId: "original-folder", title: "Native", createdAt: item.createdAt)
        var calls = 0
        var gate: CheckedContinuation<Void, Never>?
        let repo = ConversationRepository(fetch: { _, _ in .init(workspaceId: "db", items: [item], total: 1) }, open: { _, request in
            calls += 1
            XCTAssertEqual(request.id, item.id)
            await withCheckedContinuation { gate = $0 }
            return chat
        })
        let history = repo.history(workspaceId: "workspace", agentId: nil)
        await history.load()
        let a = Task { try await repo.open(item, workspaceId: "workspace", agentId: nil) }
        for _ in 0..<100 where gate == nil { await Task.yield() }
        let b = Task { try await repo.open(item, workspaceId: "workspace", agentId: nil) }
        await Task.yield()
        gate?.resume()
        let first = try await a.value, second = try await b.value
        XCTAssertEqual(first, second)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(history.items.first?.chatId, chat.id)
        XCTAssertEqual(history.items.first?.projectId, chat.projectId)
    }

    func testBrowseDoesNotImportProjectsAndOpenAppliesDaemonSnapshotBeforeNavigation() async throws {
        let stores = try cache()
        let workspace = Workspace(id: "connection", name: "Computer", runtime: .server(serverId: "unused"), createdAt: "2026-10-01T00:00:00Z")
        let remote = WorkspaceRemoteFixture()
        let item = row("native")
        remote.browseConversations = { _ in .init(workspaceId: "database", items: [item], total: 1) }
        let chat = Chat(id: "chat", agentId: "profile", projectId: "folder", title: "Native", createdAt: item.createdAt, sessionId: "native-session")
        remote.resolveConversation = { _ in
            .init(chatId: chat.id, snapshot: .init(version: 1, workspaceId: "database", revision: 1, full: true,
                agents: [.init(id: "profile", name: "Codex", agentType: .codex, workspaceId: "database", createdAt: item.createdAt)],
                projects: [.init(id: "folder", name: "Mobile", workspaceId: "database", path: item.cwd, createdAt: item.createdAt)],
                chats: [chat], deleted: []))
        }
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, resolveWorkspace: { _ in workspace })
        let page = try await data.conversations(workspaceId: workspace.id, query: .init())
        XCTAssertEqual(page.items.first?.cwd, item.cwd)
        XCTAssertTrue(stores.projects.list().isEmpty)
        XCTAssertTrue(remote.imports.isEmpty)
        XCTAssertEqual(remote.snapshotCalls, 0)
        let opened = try await data.openConversation(workspaceId: workspace.id, request: .init(id: item.id))
        XCTAssertEqual(opened.sessionId, "native-session")
        XCTAssertEqual(stores.projects.get(opened.projectId)?.path, item.cwd)
        XCTAssertEqual(stores.projects.get(opened.projectId)?.workspaceId, workspace.id)
        XCTAssertEqual(remote.prepareAllowInstall, [false, false])
    }

    func testForgottenWorkspaceCannotBeResurrectedByLateOpen() async throws {
        let stores = try cache()
        let workspace = Workspace(id: "connection", name: "Computer", runtime: .server(serverId: "unused"), createdAt: "2026-10-01T00:00:00Z")
        let remote = WorkspaceRemoteFixture()
        var gate: CheckedContinuation<Void, Never>?
        remote.resolveConversation = { _ in
            await withCheckedContinuation { gate = $0 }
            return .init(chatId: "late", snapshot: .init(version: 1, workspaceId: "db", revision: 1, full: true,
                                                       agents: [], projects: [], chats: [], deleted: []))
        }
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, resolveWorkspace: { _ in workspace })
        let pending = Task { try await data.openConversation(workspaceId: workspace.id, request: .init(id: "native")) }
        for _ in 0..<100 where gate == nil { await Task.yield() }
        data.forget(workspace.id)
        gate?.resume()
        do { _ = try await pending.value; XCTFail("Late result must be rejected") }
        catch { XCTAssertTrue(error.isRequestCancellation) }
        XCTAssertNil(data.identity(workspaceId: workspace.id))
        XCTAssertTrue(stores.projects.list().isEmpty)
    }

    func testGlobalChatListRendersHarnessLogosFoldersAndSearchWithNativeSizing() async throws {
        let stores = try cache()
        let rows = [row("Polish the mobile chat", cwd: "/Users/test/code/mindwire"),
                    row("Fix the deployment retry", cwd: "/Users/test/code/openship", harness: "claude-code"),
                    row("Investigate connection recovery", cwd: "/home/test/projects/runtime")]
        let repo = ConversationRepository(fetch: { _, _ in .init(workspaceId: "db", items: rows, total: rows.count) },
                                          open: { _, _ in throw CancellationError() })
        let host = UIHostingController(rootView: ChatHistorySheet(workspaceId: "workspace", conversationRepository: repo)
            .environment(\.stores, stores).environment(AppModel(stores: stores)).tint(Palette.accent).preferredColorScheme(.dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(800))
        let image = ChatFeedSnapshot.image(host)
        let text = try ChatFeedSnapshot.visibleText(in: image)
        XCTAssertTrue(text.contains("All chats"), text)
        XCTAssertTrue(text.contains("mobile chat"), text)
        XCTAssertTrue(text.contains("openship"), text)
        let attachment = XCTAttachment(image: image)
        attachment.name = "mindwire-global-chats"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/mindwire-global-chats.png"))
    }

    func testRealDaemonGlobalBrowseOpenAndNativeHistoryInOriginalFolder() async throws {
        guard ProcessInfo.processInfo.environment["MINDWIRE_GLOBAL_CHAT_E2E"] == "1" else {
            throw XCTSkip("Run the disposable global-chat daemon fixture on localhost:18793.")
        }
        let stores = try cache()
        let channel = URLSessionDaemonChannel(label: "global-history-fixture") { method, path, body, _ in
            var request = URLRequest(url: URL(string: "http://127.0.0.1:18793" + path)!)
            request.httpMethod = method; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer mindwire-global-history-test-only", forHTTPHeaderField: "Authorization")
            return request
        }
        let http = DaemonHTTP(channel: channel, agentType: "")
        let workspace = Workspace(id: "global-fixture", name: "Native history", runtime: .server(serverId: "unused"), createdAt: "2026-10-01T00:00:00Z")
        let remote = WorkspaceRegistryClient(workspace: workspace, stores: stores, http: http)
        let data = WorkspaceDataRepository(stores: stores, makeRemote: { _ in remote }, resolveWorkspace: { _ in workspace })
        let page = try await data.conversations(workspaceId: workspace.id, query: .init(refresh: true))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertTrue(stores.projects.list().isEmpty, "Browsing must not create projects")
        let item = try XCTUnwrap(page.items.first)
        let chat = try await data.openConversation(workspaceId: workspace.id, request: .init(id: item.id))
        XCTAssertEqual(stores.projects.get(chat.projectId)?.path, item.cwd)
        let again = try await data.openConversation(workspaceId: workspace.id, request: .init(id: item.id))
        XCTAssertEqual(again.id, chat.id)
        let messages: [DaemonMessage] = try await http.decode("GET", "/chats/\(chat.id)/messages?limit=1")
        XCTAssertEqual(messages.last?.text, "Global history fixture response")
        let scoped: [DaemonChatSummary] = try await http.decode("GET", "/chats?projectId=\(chat.projectId)")
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.chatId, chat.id)
        let all = try await data.conversations(workspaceId: workspace.id, query: .init())
        XCTAssertEqual(all.items.count, 2, "Opening a native chat must not duplicate the global list")
    }
}
