#if DEBUG
import SwiftUI

/// Actual widget content at Home Screen sizes, using offline artwork and status fixtures.
struct WidgetPreviewScene: View {
    let apps: [AppShortcut]
    @State private var shortcuts: [WidgetAppShortcut] = []
    @State private var assistantArtwork: Data?
    private let layout = ProcessInfo.processInfo.environment["MINDWIRE_WIDGET_PREVIEW"] ?? "all"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Mindwire widgets").font(.title2.weight(.semibold))
                if layout == "all" {
                    AskMindwireWidgetContent(snapshot: sample(.approval), date: .now, expanded: true)
                        .modifier(WidgetPreviewCard(width: 338, height: 158))
                    HStack(spacing: 22) {
                        AskMindwireWidgetContent(snapshot: sample(.working), date: .now)
                            .modifier(WidgetPreviewCard(width: 158, height: 158))
                        AskMindwireWidgetContent(snapshot: .init(catalog: WidgetCatalog(assistantArtwork: assistantArtwork)), date: .now)
                            .modifier(WidgetPreviewCard(width: 158, height: 158))
                    }
                    AppsWidgetContent(apps: shortcuts)
                        .modifier(WidgetPreviewCard(width: 338, height: 158))
                }
                if layout != "states" {
                    AppsWidgetContent(apps: shortcuts, large: true)
                        .modifier(WidgetPreviewCard(width: 338, height: 354))
                }
                ForEach([WidgetWorkState.approval, .input, .finished, .failed, .stopped, .working], id: \.self) { state in
                    AskMindwireWidgetContent(snapshot: sample(state), date: state == .working ? .now.addingTimeInterval(600) : .now,
                                             expanded: true)
                        .modifier(WidgetPreviewCard(width: 338, height: 158))
                }
            }
            .padding(24).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            shortcuts = apps.prefix(4).map { app in
                .init(id: app.id, name: app.name, computerName: "Mindwire Cloud", icon: app.icon,
                      artwork: WidgetCatalogPublisher.artwork(id: app.id, icon: app.icon))
            }
            if shortcuts.isEmpty {
                shortcuts = ["Daily brief", "Expenses", "Planner", "Reading list"].enumerated().map { index, name in
                    let icon = ["sun.max.fill", "chart.pie.fill", "calendar", "books.vertical.fill"][index]
                    return .init(id: name, name: name, computerName: index % 2 == 0 ? "MacBook Pro" : "Mindwire Cloud", icon: icon,
                                 artwork: WidgetCatalogPublisher.artwork(id: name, icon: icon))
                }
            }
            assistantArtwork = WidgetCatalogPublisher.artwork(id: "mindwire", icon: "peach-pebble")
        }
    }

    private func sample(_ state: WidgetWorkState) -> WidgetAssistantSnapshot {
        let bots = [WidgetBot(id: "mindwire", name: "Mindwire", artworkKey: "", artwork: assistantArtwork),
                    WidgetBot(id: "research", name: "Research", artworkKey: "", artwork: shortcuts.last?.artwork)]
        return .init(catalog: WidgetCatalog(assistantArtwork: assistantArtwork, bots: bots, activity: [
            .init(chatID: "preview", botID: "mindwire", title: "Your morning report", state: state, runID: "preview", observedAt: .now),
            .init(chatID: "research", botID: "research", title: "Research for your trip", state: state == .finished || state == .stopped ? state : .working,
                  runID: "preview-2", observedAt: .now.addingTimeInterval(-60))
        ]))
    }
}

private struct WidgetPreviewCard: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    func body(content: Content) -> some View {
        content.padding(16).frame(width: width, height: height)
            .background { MindwireWidgetBackground() }
            .clipShape(.rect(cornerRadius: 24))
    }
}
#endif
