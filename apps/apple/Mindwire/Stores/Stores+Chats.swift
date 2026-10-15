import Foundation

extension Stores {
    func chats(forWorkspaceId id: String) -> [Chat] {
        let agentIDs = Set(agents(forWorkspaceId: id).map(\.id))
        return chatsByRecency().filter { agentIDs.contains($0.agentId) }
    }
    /// All of an agent's chats (across every project) — used to group by project on the agent page.
    func chats(forAgentId id: String) -> [Chat] {
        chats.list().filter { $0.agentId == id }.sorted { ($0.lastActivityAt, $0.id) > ($1.lastActivityAt, $1.id) }
    }

    /// An agent's chats within one project (the project-scoped chat list).
    func chats(forAgentId agentId: String, projectId: String) -> [Chat] {
        chats.list().filter { $0.agentId == agentId && $0.projectId == projectId }
            .sorted { ($0.lastActivityAt, $0.id) > ($1.lastActivityAt, $1.id) }
    }

    func chats(forProjectId id: String) -> [Chat] {
        chats.list().filter { $0.projectId == id }.sorted { ($0.lastActivityAt, $0.id) > ($1.lastActivityAt, $1.id) }
    }

    func chatsByRecency() -> [Chat] {
        chats.list().sorted { ($0.lastActivityAt, $0.id) > ($1.lastActivityAt, $1.id) }
    }

    @discardableResult
    func createChat(agentId: String, projectId: String, title: String = "New chat") -> Chat {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = Chat(id: newId(), agentId: agentId, projectId: projectId,
                        title: trimmed.isEmpty ? "New chat" : trimmed,
                        createdAt: isoNow(), sessionId: nil)
        chats.save(chat)
        return chat
    }

    func renameChat(_ id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var c = chats.get(id) else { return }
        c.title = trimmed
        c.titleIsUserSet = true   // a manual rename pins the title — the agent title won't override it
        chats.save(c)
    }

    /// Adopt the AGENT's title (GET /chats → `DaemonChatSummary.title`). The daemon now serves the
    /// agent's own auto-generated title (Claude's `ai-title`), falling back to a first-message snippet
    /// only until the agent emits one — so this title UPGRADES over the chat's life. We therefore
    /// adopt any newer non-placeholder title, EXCEPT when the user manually renamed the chat
    /// (`titleIsUserSet`), which always wins. "New chat" is the daemon's empty-fallback sentinel and is
    /// never adopted over an existing title.
    func syncChatTitle(_ id: String, daemonTitle: String?) {
        let incoming = (daemonTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty, incoming != "New chat",
              var c = chats.get(id), c.title != incoming,
              !(c.titleIsUserSet ?? false) else { return }
        c.title = incoming
        chats.save(c)
    }

    /// Bulk-adopt titles from a daemon `/chats` listing (keyed on chatId).
    func syncChatTitles(_ summaries: [DaemonChatSummary]) {
        let byID = Dictionary(summaries.map { ($0.chatId, $0) }, uniquingKeysWith: { _, latest in latest })
        var changed = false
        let updated = chats.list().map { saved -> Chat in
            guard let summary = byID[saved.id] else { return saved }
            var chat = saved
            let title = (summary.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, title != "New chat", chat.titleIsUserSet != true { chat.title = title }
            if let activity = summary.updatedAt, activity > chat.lastActivityAt { chat.updatedAt = activity }
            if chat != saved { changed = true }
            return chat
        }
        if changed {
            // A native inventory can contain hundreds of sessions. Publish one
            // cache update instead of writing and rerendering once per row.
            chats.replaceAll(updated)
        }
    }

    @MainActor
    func deleteChat(_ id: String) {
        chatSessions.remove(id)
        chatDrafts.remove(id)
        chats.remove(id)
    }

    @MainActor
    func deleteChats(forAgentId id: String) {
        for c in chats.list() where c.agentId == id { deleteChat(c.id) }
    }

    @MainActor
    func deleteChats(forProjectId id: String) {
        for c in chats.list() where c.projectId == id { deleteChat(c.id) }
    }
}
