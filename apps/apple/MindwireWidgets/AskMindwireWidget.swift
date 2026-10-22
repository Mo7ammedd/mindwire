import SwiftUI
import WidgetKit

struct AskMindwireEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetAssistantSnapshot
    var relevance: TimelineEntryRelevance? {
        guard let focus = snapshot.focus, !focus.isStale(at: date) else { return nil }
        return TimelineEntryRelevance(score: focus.state.needsAttention ? 100 : 25,
                                      duration: max(0, focus.expiresAt.timeIntervalSince(date)))
    }
}

struct AskMindwireProvider: TimelineProvider {
    func placeholder(in context: Context) -> AskMindwireEntry { .init(date: .now, snapshot: .init()) }
    func getSnapshot(in context: Context, completion: @escaping (AskMindwireEntry) -> Void) {
        completion(.init(date: .now, snapshot: read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AskMindwireEntry>) -> Void) {
        let now = Date(), snapshot = read()
        // Future entries change stale wording without a background process or network polling.
        let expirations = Set(snapshot.activity.prefix(2).map(\.expiresAt).filter { $0 > now }).sorted()
        let entries = ([now] + expirations).map { AskMindwireEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .never))
    }
    private func read() -> WidgetAssistantSnapshot {
        .init(catalog: MindwireWidget.readCatalog(), updates: WidgetPushUpdates.read())
    }
}

private struct AskMindwireWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AskMindwireEntry
    var body: some View {
        AskMindwireWidgetContent(snapshot: entry.snapshot, date: entry.date, expanded: family == .systemMedium)
            .widgetURL(entry.snapshot.destination)
            .containerBackground(for: .widget) { MindwireWidgetBackground() }
    }
}

struct AskMindwireWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MindwireWidget.askKind, provider: AskMindwireProvider()) { entry in
            AskMindwireWidgetView(entry: entry)
        }
        .configurationDisplayName("Ask Mindwire")
        .description("See what your bots are doing, review requests, and pick up a conversation.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MindwireWidgets: WidgetBundle {
    var body: some Widget {
        MindwireAppsWidget()
        AskMindwireWidget()
    }
}
