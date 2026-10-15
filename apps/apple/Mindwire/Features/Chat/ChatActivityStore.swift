import SwiftUI
import Observation

/// Shared, daemon-owned run state for every chat list. Local chat records only supply navigation.
@MainActor
@Observable
final class ChatActivityStore {
    static let shared = ChatActivityStore()

    private(set) var summaries: [String: DaemonChatSummary] = [:]
    @ObservationIgnored private var workspaceChats: [String: Set<String>] = [:]
    @ObservationIgnored private var revisions: [String: Int] = [:]
    private var runStarts: [String: RunStart] = [:]
    @ObservationIgnored private var refreshes: [String: Task<Void, Never>] = [:]
    private var native: [String: NativeObservation] = [:]
    @ObservationIgnored private var nativeCheckedAt: [String: Date] = [:]

    private struct NativeObservation: Equatable {
        var activity: NativeSessionActivity
        var connected: Bool
    }

    private struct RunStart: Equatable {
        let id: String
        let createdAt: String
    }

    func status(_ chatId: String) -> RunStatus? {
        if let value = native[chatId], value.connected || Date().timeIntervalSince(nativeCheckedAt[chatId] ?? .distantPast) < 15 {
            return value.activity.isRunning ? .running : .done
        }
        return summaries[chatId]?.lastStatus.flatMap(RunStatus.init(rawValue:))
    }

    /// Native ownership is separate from daemon run IDs: native badges must
    /// never cause a list to poll /runs with a fabricated identifier.
    func recordNative(_ value: NativeSessionActivity?, chatId: String, connected: Bool) {
        guard let value, value.owner == "native" else {
            if native[chatId] != nil { native[chatId] = nil }
            nativeCheckedAt[chatId] = nil
            return
        }
        if native[chatId] == nil, native.count >= 32,
           let oldest = nativeCheckedAt.min(by: { $0.value < $1.value })?.key {
            native[oldest] = nil
            nativeCheckedAt[oldest] = nil
        }
        let updated = NativeObservation(activity: value, connected: connected)
        if native[chatId] != updated { native[chatId] = updated }
        nativeCheckedAt[chatId] = .now
    }

    func detachNative(_ chatId: String) {
        guard native[chatId]?.connected == true else { return }
        native[chatId]?.connected = false
        nativeCheckedAt[chatId] = .now
    }

    func remove(_ chatId: String) {
        // Invalidate any list response that began before the acknowledged deletion.
        revisions[chatId, default: 0] += 1
        summaries[chatId] = nil
        native[chatId] = nil
        nativeCheckedAt[chatId] = nil
        runStarts[chatId] = nil
        for workspaceId in Array(workspaceChats.keys) { workspaceChats[workspaceId]?.remove(chatId) }
    }

    func title(_ chat: Chat) -> String {
        guard chat.titleIsUserSet != true, let title = summaries[chat.id]?.title,
              !title.isEmpty, title != "New chat" else { return chat.title }
        return title
    }

    func lastActivity(_ chat: Chat) -> Date? {
        [chat.createdAt, chat.updatedAt, summaries[chat.id]?.updatedAt]
            .compactMap { $0.flatMap(RelativeTime.date) }.max()
    }

    func runStartedAt(_ chatId: String) -> Date? {
        if let value = native[chatId], value.activity.isRunning,
           value.connected || Date().timeIntervalSince(nativeCheckedAt[chatId] ?? .distantPast) < 15 {
            return value.activity.startedAt.flatMap(RelativeTime.date)
        }
        guard status(chatId) == .running, let start = runStarts[chatId],
              start.id == summaries[chatId]?.lastRunId else { return nil }
        return RelativeTime.date(start.createdAt)
    }

    func ordered(_ chats: [Chat], limit: Int? = nil) -> [Chat] {
        let sorted = chats.sorted {
            let a = status($0.id) == .running, b = status($1.id) == .running
            if a != b { return a }
            let left = max(summaries[$0.id]?.updatedAt ?? "", $0.lastActivityAt)
            let right = max(summaries[$1.id]?.updatedAt ?? "", $1.lastActivityAt)
            return left == right ? $0.id < $1.id : left > right
        }
        guard let limit else { return sorted }
        // Running chats sort first; summaries stay bounded and All chats keeps the full list.
        return Array(sorted.prefix(max(0, limit)))
    }

    func isRunning(agentId: String, stores: Stores, projectId: String? = nil) -> Bool {
        stores.chats(forAgentId: agentId).contains {
            (projectId == nil || $0.projectId == projectId) && status($0.id) == .running
        }
    }

    /// A POST/get-run response is authoritative immediately, even before the next list refresh.
    func record(_ run: DaemonRun, workspaceId: String? = nil, stores: Stores? = nil) {
        if let start = runStarts[run.chatId], start.createdAt > run.createdAt { return }
        if let summary = summaries[run.chatId] {
            // An old observer may finish after another device has started the next turn.
            if let latest = summary.lastRunId, latest != run.id,
               let updated = summary.updatedAt, updated > (run.endedAt ?? run.createdAt) { return }
            // Terminal runs never become running again because an earlier GET arrived late.
            if summary.lastRunId == run.id, summary.lastStatus != nil,
               summary.lastStatus != RunStatus.running.rawValue, run.status == .running { return }
        }
        let wasRunning = status(run.chatId) == .running
        if run.status == .running, native[run.chatId] != nil { native[run.chatId] = nil; nativeCheckedAt[run.chatId] = nil }
        let start = RunStart(id: run.id, createdAt: run.createdAt)
        if runStarts[run.chatId] != start { runStarts[run.chatId] = start }
        revisions[run.chatId, default: 0] += 1
        var summary = summaries[run.chatId] ?? DaemonChatSummary(chatId: run.chatId)
        summary.lastRunId = run.id
        summary.lastStatus = run.status.rawValue
        summary.updatedAt = run.endedAt ?? run.createdAt
        if summaries[run.chatId] != summary { summaries[run.chatId] = summary }
        if let workspaceId { workspaceChats[workspaceId, default: []].insert(run.chatId) }
        if wasRunning, run.status != .running, let stores { refreshProjectGit(chatIds: [run.chatId], stores: stores) }
    }

    /// Apply a complete workspace snapshot, preserving any newer run response received in flight.
    func receive(_ incoming: [DaemonChatSummary], workspaceId: String, since baseline: [String: Int]? = nil) {
        let current = Set(incoming.map(\.chatId))
        func unchanged(_ id: String) -> Bool { baseline == nil || baseline?[id] == revisions[id] }
        for id in (workspaceChats[workspaceId] ?? []).subtracting(current) where unchanged(id) {
            if summaries[id] != nil { summaries[id] = nil }
            native[id] = nil
            nativeCheckedAt[id] = nil
            workspaceChats[workspaceId]?.remove(id)
            if runStarts[id] != nil { runStarts[id] = nil }
        }
        for summary in incoming where unchanged(summary.chatId) {
            if let start = runStarts[summary.chatId], start.id != summary.lastRunId { runStarts[summary.chatId] = nil }
            // Polling an unchanged workspace must not invalidate every visible chat row
            // or the menus presented above its project/agent page.
            if summaries[summary.chatId] != summary { summaries[summary.chatId] = summary }
        }
        workspaceChats[workspaceId, default: []].formUnion(current)
    }

    /// Cold lists fetch each active run's start once. A chat's last-edit date can change during
    /// a turn, so it must never be used as an elapsed-time clock. Shared refreshes deduplicate
    /// these reads across list surfaces; row timers only render the cached timestamp.
    func refreshRunStarts(_ incoming: [DaemonChatSummary], readRun: (String) async throws -> DaemonRun) async {
        for summary in incoming {
            if Task.isCancelled { return }
            guard let id = summary.lastRunId, summary.lastStatus == RunStatus.running.rawValue,
                  summaries[summary.chatId]?.lastRunId == id, status(summary.chatId) == .running,
                  runStarts[summary.chatId]?.id != id else { continue }
            guard let run = try? await readRun(id), run.id == id, run.chatId == summary.chatId,
                  RelativeTime.date(run.createdAt) != nil,
                  summaries[summary.chatId]?.lastRunId == id, status(summary.chatId) == .running else { continue }
            runStarts[summary.chatId] = RunStart(id: id, createdAt: run.createdAt)
        }
    }

    func refresh(agentIds: [String], stores: Stores) async {
        var representatives: [String: String] = [:]
        for id in agentIds.sorted() {
            if let workspaceId = stores.agents.get(id)?.workspaceId {
                representatives[workspaceId] = representatives[workspaceId] ?? id
            }
        }
        var pending: [Task<Void, Never>] = []
        for (workspaceId, agentId) in representatives {
            if let refresh = refreshes[workspaceId] { pending.append(refresh); continue }
            let baseline = revisions
            let session = DaemonManager.shared.session(for: agentId, stores: stores)
            let task = Task {
                defer { refreshes[workspaceId] = nil }
                do {
                    let incoming = try await session.readChatActivity()
                    let runningBefore = Set(summaries.values.filter { $0.lastStatus == RunStatus.running.rawValue }.map(\.chatId))
                    receive(incoming, workspaceId: workspaceId, since: baseline)
                    stores.syncChatTitles(incoming)
                    let finished = runningBefore.filter { status($0) != .running }
                    if !finished.isEmpty { refreshProjectGit(chatIds: finished, stores: stores) }
                    await refreshRunStarts(incoming) { id in try await session.readRunActivity(id) }
                    await refreshNativeActivity(workspaceId: workspaceId, stores: stores)
                } catch {
                    // Keep the last daemon state while disconnected; never invent an idle state.
                }
            }
            refreshes[workspaceId] = task
            pending.append(task)
        }
        for task in pending { await task.value }
    }

    private func refreshNativeActivity(workspaceId: String, stores: Stores) async {
        // Revalidate only conversations already attached by this app. No scan
        // through historical chats, and no polling when no list is visible.
        for id in Array(native.keys).sorted() {
            guard !Task.isCancelled, let previous = native[id], !previous.connected,
                  let checkedAt = nativeCheckedAt[id], Date().timeIntervalSince(checkedAt) >= 2,
                  let chat = stores.chats.get(id), stores.agents.get(chat.agentId)?.workspaceId == workspaceId else { continue }
            let session = DaemonManager.shared.session(for: chat.agentId, stores: stores)
            do {
                let value = try await session.readNativeActivity(id)
                guard nativeCheckedAt[id] == checkedAt else { continue }
                recordNative(value, chatId: id, connected: false)
            } catch { /* An unreachable owner is not an authoritative idle state. */ }
        }
    }

    private func refreshProjectGit(chatIds: Set<String>, stores: Stores) {
        let ids = Set(stores.chats.list().filter { chatIds.contains($0.id) }.map(\.projectId))
        for id in ids {
            guard let project = stores.projects.get(id) else { continue }
            stores.projectPresentation.invalidateGit(id)
            Task { await stores.workspaceData.refreshProjectPresentation(workspaceId: project.workspaceId, projectId: id) }
        }
    }

    func watch(agentIds: [String], stores: Stores) async {
        guard !agentIds.isEmpty else { return }
        while !Task.isCancelled {
            await refresh(agentIds: agentIds, stores: stores)
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }
}

private struct ChatActivityObserver: ViewModifier {
    let agentIds: [String]
    @Environment(\.stores) private var stores
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: WatchKey(agentIds: Array(Set(agentIds)).sorted(), active: scenePhase != .background)) {
            guard scenePhase != .background else { return }
            await ChatActivityStore.shared.watch(agentIds: agentIds, stores: stores)
        }
    }

    private struct WatchKey: Hashable {
        let agentIds: [String]
        let active: Bool
    }
}

extension View {
    /// Poll only while this list is visible and the app is in the foreground.
    func observeChatActivity(agentIds: [String]) -> some View {
        modifier(ChatActivityObserver(agentIds: agentIds))
    }
}
