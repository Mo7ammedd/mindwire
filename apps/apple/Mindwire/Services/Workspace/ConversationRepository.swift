import Foundation
import Observation

/// A small, on-demand metadata cache shared by agent and workspace browsers.
/// Transcripts continue through ChatSessionStore and the native harness reader.
@MainActor
final class ConversationRepository {
    typealias Fetch = @MainActor (String, ConversationQuery) async throws -> ConversationPage
    typealias Open = @MainActor (String, ConversationOpenRequest) async throws -> Chat
    private let fetch: Fetch
    private let resolve: Open
    private let now: () -> Date
    private var entries: [Key: ConversationHistory] = [:]
    private var recency: [Key] = []
    private var opening: [String: Task<Chat, Error>] = [:]
    private var generations: [String: Int] = [:]

    private struct Key: Hashable {
        let workspaceId: String
        let agentId: String?
        let search: String
    }

    init(stores: Stores, now: @escaping () -> Date = Date.init) {
        self.now = now
        fetch = { id, query in try await stores.workspaceData.conversations(workspaceId: id, query: query) }
        resolve = { id, request in try await stores.workspaceData.openConversation(workspaceId: id, request: request) }
    }

    init(now: @escaping () -> Date = Date.init, fetch: @escaping Fetch, open: @escaping Open) {
        self.now = now
        self.fetch = fetch
        self.resolve = open
    }

    func history(workspaceId: String, agentId: String?, search: String = "") -> ConversationHistory {
        let key = Key(workspaceId: workspaceId, agentId: agentId, search: search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        recency.removeAll { $0 == key }
        recency.append(key)
        if let cached = entries[key] { return cached }
        let history = ConversationHistory(query: .init(agentId: agentId, search: key.search), now: now) { [fetch] query in
            try await fetch(workspaceId, query)
        }
        entries[key] = history
        // A presented screen retains its history independently if its entry is evicted.
        while recency.count > 12 { entries[recency.removeFirst()] = nil }
        return history
    }

    func open(_ conversation: Conversation, workspaceId: String, agentId: String?) async throws -> Chat {
        let key = workspaceId + "\u{1f}" + conversation.id
        if let task = opening[key] { return try await task.value }
        let generation = generations[workspaceId, default: 0]
        let task = Task { @MainActor in
            let chat = try await self.resolve(workspaceId, .init(id: conversation.id, agentId: agentId))
            guard generation == self.generations[workspaceId, default: 0] else { throw CancellationError() }
            for (key, history) in self.entries where key.workspaceId == workspaceId {
                history.didOpen(conversation.id, chat: chat)
            }
            return chat
        }
        opening[key] = task
        defer { if generation == generations[workspaceId, default: 0] { opening[key] = nil } }
        return try await task.value
    }

    func forget(workspaceId: String) {
        generations[workspaceId, default: 0] += 1
        for (key, history) in entries where key.workspaceId == workspaceId {
            history.discard()
            entries[key] = nil
        }
        recency.removeAll { $0.workspaceId == workspaceId }
        let prefix = workspaceId + "\u{1f}"
        for (key, task) in opening where key.hasPrefix(prefix) {
            task.cancel()
            opening[key] = nil
        }
    }
}

@MainActor @Observable
final class ConversationHistory {
    private(set) var items: [Conversation] = []
    private(set) var total: Int?
    private(set) var issues: [WorkspaceSessionDiscoveryIssue] = []
    private(set) var error: String?
    private(set) var requiresUpdate = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var nextCursor: String?
    let query: ConversationQuery
    private var identity: String?
    private var loadedAt: Date?
    private var failedAt: Date?
    private var generation = 0
    @ObservationIgnored private let fetch: @MainActor (ConversationQuery) async throws -> ConversationPage
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var job: Task<Void, Never>?

    init(query: ConversationQuery, now: @escaping () -> Date = Date.init,
         fetch: @escaping @MainActor (ConversationQuery) async throws -> ConversationPage) {
        self.query = query
        self.now = now
        self.fetch = fetch
    }

    func load(force: Bool = false) async {
        if let job {
            let wasMore = isLoadingMore
            await job.value
            if force && wasMore { await load(force: true) }
            return
        }
        if !force {
            if let failedAt, now().timeIntervalSince(failedAt) < 5 { return }
            if failedAt == nil, let loadedAt, now().timeIntervalSince(loadedAt) < 60 { return }
        }
        await request(more: false, force: force)
    }

    func loadMore() async {
        guard job == nil, nextCursor != nil else { return }
        await request(more: true, force: false)
    }

    private func request(more: Bool, force: Bool) async {
        var request = query
        request.cursor = more ? nextCursor : nil
        request.refresh = force
        let generation = self.generation
        isLoading = !more
        isLoadingMore = more
        let task = Task { @MainActor in
            defer {
                if generation == self.generation {
                    self.isLoading = false
                    self.isLoadingMore = false
                    self.job = nil
                }
            }
            do {
                let page = try await self.fetch(request)
                guard generation == self.generation else { return }
                if more, let identity = self.identity, identity != page.workspaceId {
                    self.items = []
                    self.nextCursor = nil
                    self.loadedAt = nil
                    throw BackendError.message(t("chat.all.workspaceChanged"))
                }
                var combined = more ? self.items : []
                var ids = Set(combined.map(\.id))
                var chats = Set(combined.compactMap(\.chatId))
                for row in page.items {
                    guard ids.insert(row.id).inserted, row.chatId.map({ chats.insert($0).inserted }) ?? true else { continue }
                    combined.append(row)
                }
                self.items = combined
                self.identity = page.workspaceId
                self.total = page.total
                self.nextCursor = page.nextCursor
                self.issues = page.issues ?? []
                self.error = nil
                self.requiresUpdate = false
                self.loadedAt = self.now()
                self.failedAt = nil
            } catch {
                guard generation == self.generation, !error.isRequestCancellation else { return }
                self.error = error.localizedDescription
                if case WorkspaceRegistryError.conversationBrowserUnavailable = error { self.requiresUpdate = true }
                if case WorkspaceRegistryError.updateRequired = error { self.requiresUpdate = true }
                self.failedAt = self.now()
            }
        }
        job = task
        await task.value
    }

    func didOpen(_ id: String, chat: Chat) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].chatId = chat.id
        items[index].agentId = chat.agentId
        items[index].projectId = chat.projectId
    }

    func discard() {
        generation += 1
        job?.cancel()
        job = nil
        items = []
        total = nil
        nextCursor = nil
        identity = nil
        loadedAt = nil
        failedAt = nil
        isLoading = false
        isLoadingMore = false
    }
}
