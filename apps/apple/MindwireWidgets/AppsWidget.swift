import AppIntents
import SwiftUI
import WidgetKit

struct WidgetAppEntity: AppEntity {
    let id: String
    let name: String
    let computerName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static var defaultQuery = WidgetAppQuery()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(computerName)")
    }

    init(_ app: WidgetAppShortcut) { id = app.id; name = app.name; computerName = app.computerName }
}

struct WidgetAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetAppEntity] {
        let apps = MindwireWidget.readCatalog().apps
        return identifiers.compactMap { id in apps.first { $0.id == id }.map(WidgetAppEntity.init) }
    }
    func suggestedEntities() async throws -> [WidgetAppEntity] {
        MindwireWidget.readCatalog().apps.map(WidgetAppEntity.init)
    }
    func entities(matching string: String) async throws -> [WidgetAppEntity] {
        MindwireWidget.readCatalog().apps.filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.computerName.localizedCaseInsensitiveContains(string)
        }.map(WidgetAppEntity.init)
    }
}

struct AppsWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "App shortcuts"
    static var description = IntentDescription("Choose your shortcuts. Empty slots use your other apps automatically.")

    @Parameter(title: "First app") var first: WidgetAppEntity?
    @Parameter(title: "Second app") var second: WidgetAppEntity?
    @Parameter(title: "Third app") var third: WidgetAppEntity?
    @Parameter(title: "Fourth app") var fourth: WidgetAppEntity?

    func shortcuts(in catalog: WidgetCatalog) -> [WidgetAppShortcut] {
        let slots = [first, second, third, fourth]
        let configuredIDs = Set(slots.compactMap { $0?.id })
        var remaining = catalog.apps.filter { !configuredIDs.contains($0.id) }
        var selected: [WidgetAppShortcut] = []
        var used = Set<String>()
        // Resolve current metadata, so edits and deletions never leave stale shortcuts.
        for entity in slots {
            if let entity, let app = catalog.apps.first(where: { $0.id == entity.id }), used.insert(app.id).inserted {
                selected.append(app)
            } else if !remaining.isEmpty {
                selected.append(remaining.removeFirst())
            }
        }
        return selected
    }
}

struct AppsWidgetEntry: TimelineEntry {
    let date: Date
    let apps: [WidgetAppShortcut]
}

struct AppsWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AppsWidgetEntry {
        .init(date: .now, apps: ["Planner", "Reports", "Notes", "Tracker"].map {
            .init(id: $0, name: $0, computerName: "", icon: nil, artwork: nil)
        })
    }
    func snapshot(for configuration: AppsWidgetConfiguration, in context: Context) async -> AppsWidgetEntry {
        .init(date: .now, apps: configuration.shortcuts(in: MindwireWidget.readCatalog()))
    }
    func timeline(for configuration: AppsWidgetConfiguration, in context: Context) async -> Timeline<AppsWidgetEntry> {
        let entry = await snapshot(for: configuration, in: context)
        return Timeline(entries: [entry], policy: .never)
    }
}

private struct AppsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AppsWidgetEntry
    var body: some View {
        AppsWidgetContent(apps: entry.apps, large: family == .systemLarge)
            .widgetURL(WidgetLink.apps.url)
            .containerBackground(for: .widget) { MindwireWidgetBackground() }
    }
}

struct MindwireAppsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: MindwireWidget.appsKind, intent: AppsWidgetConfiguration.self,
                               provider: AppsWidgetProvider()) { entry in
            AppsWidgetView(entry: entry)
        }
        .configurationDisplayName("Your apps")
        .description("Open your Mindwire apps in one tap.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
