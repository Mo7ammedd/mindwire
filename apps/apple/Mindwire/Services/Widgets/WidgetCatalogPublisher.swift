import SwiftUI
import WidgetKit
import OSLog

/// Exports artwork from the existing renderer, only when app metadata changes.
@MainActor
enum WidgetCatalogPublisher {
    static func publish(stores: Stores, workspaces availableWorkspaces: [Workspace], activity: [WidgetChatActivity]) async {
        #if !targetEnvironment(macCatalyst)
        guard let url = MindwireWidget.catalogURL else { return }
        let previous = MindwireWidget.readCatalog()
        let previousApps = Dictionary(previous.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaces = Dictionary(availableWorkspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let apps = AppShortcut.catalog(stores.apps.list(), workspaceIDs: Set(workspaces.keys))
        var next = WidgetCatalog()
        for app in apps {
            guard !Task.isCancelled else { return }
            let old = previousApps[app.id]
            let image = old?.icon == app.icon && old?.artwork != nil ? old?.artwork : artwork(id: app.id, icon: app.icon)
            next.apps.append(.init(id: app.id, name: app.name, computerName: workspaces[app.workspaceId] ?? "",
                                   icon: app.icon, artwork: image))
            await Task.yield()
        }
        let master = stores.bots.list().first { !$0.archived && $0.isMaster && $0.agentId == stores.experience.assistantAgentID }
        let id = master?.id ?? "mindwire", icon = master?.icon ?? "peach-pebble"
        next.assistantArtworkKey = id + ":" + icon
        next.assistantArtwork = previous.assistantArtworkKey == next.assistantArtworkKey && previous.assistantArtwork != nil
            ? previous.assistantArtwork : artwork(id: id, icon: icon)
        let previousBots = Dictionary((previous.bots ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        next.bots = stores.bots.list().filter { !$0.archived && workspaces[$0.workspaceId] != nil }.map { bot in
            let key = bot.id + ":" + (bot.icon ?? "")
            let old = previousBots[bot.id]
            return WidgetBot(id: bot.id, name: bot.name, artworkKey: key,
                artwork: old?.artworkKey == key ? old?.artwork : artwork(id: bot.id, icon: bot.icon))
        }.sorted { $0.id < $1.id }
        let previousActivity = Dictionary((previous.activity ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let knownChats = Set(stores.chats.list().map(\.id))
        let availableBots = Set((next.bots ?? []).map(\.id))
        let observedIDs = Set(activity.map(\.id))
        // Preserve last known state on a cold launch until the daemon has answered.
        var rows = (previous.activity ?? []).filter {
            knownChats.contains($0.id) && availableBots.contains($0.botID) && !observedIDs.contains($0.id)
        }
        rows += activity.filter { availableBots.contains($0.botID) }.map { observation in
            var row = observation
            if let old = previousActivity[row.id], row.sameContent(as: old) { row.observedAt = old.observedAt }
            else if row.state == .working || row.state == .approval || row.state == .input { row.observedAt = .now }
            // A discovered historical result keeps its real completion date, not launch time.
            return row
        }
        next.activity = Array(rows.sorted {
            $0.state.priority == $1.state.priority ? $0.observedAt > $1.observedAt : $0.state.priority < $1.state.priority
        }.prefix(64))
        guard !Task.isCancelled, next != previous else { return }
        do {
            let data = try JSONEncoder().encode(next)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if next.apps != previous.apps { WidgetCenter.shared.reloadTimelines(ofKind: MindwireWidget.appsKind) }
            if next.activity != previous.activity || next.bots != previous.bots || next.assistantArtwork != previous.assistantArtwork {
                WidgetCenter.shared.reloadTimelines(ofKind: MindwireWidget.askKind)
            }
        } catch {
            Logger(subsystem: "com.oblien.mindwire", category: "Widgets").error("Could not update the widget catalog: \(error.localizedDescription)")
        }
        #endif
    }

    static func artwork(id: String, icon: String?) -> Data? {
        let renderer = ImageRenderer(content: SavedAppIcon(id: id, icon: icon, size: 48))
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }
}
