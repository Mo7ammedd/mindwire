import SwiftUI
import WidgetKit

private enum WidgetStyle {
    static let orange = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.96, green: 0.63, blue: 0.40, alpha: 1)
            : UIColor(red: 0.67, green: 0.29, blue: 0.10, alpha: 1)
    })
    static let peach = Color(red: 0.94, green: 0.58, blue: 0.35)
    static let ink = Color(red: 0.18, green: 0.13, blue: 0.10)
}

struct MindwireWidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack(alignment: .topTrailing) {
            scheme == .dark ? Color(red: 0.09, green: 0.085, blue: 0.08)
                : Color(red: 0.99, green: 0.98, blue: 0.96)
            RadialGradient(colors: [WidgetStyle.peach.opacity(scheme == .dark ? 0.13 : 0.09), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 220)
        }
    }
}

struct WidgetAppArtwork: View {
    let data: Data?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFit()
            } else {
                Image(systemName: "sparkles").font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(WidgetStyle.orange).widgetAccentable()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct WidgetArrow: View {
    var body: some View {
        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(.primary.opacity(0.05), in: Circle())
    }
}

struct AppsWidgetContent: View {
    let apps: [WidgetAppShortcut]
    var large = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 16 : 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(WidgetStyle.orange).widgetAccentable()
                Text("Your apps").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Link(destination: WidgetLink.apps.url) { WidgetArrow() }.accessibilityLabel("Open all apps")
            }
            if apps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Make room for an idea.").font(.system(size: 18, weight: .semibold))
                    Text("Your Mindwire apps will appear here.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if large {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(apps.prefix(4)) { app in
                        Link(destination: WidgetLink.app(app.id).url) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { WidgetAppArtwork(data: app.artwork, size: 44); Spacer(minLength: 0) }
                                Spacer(minLength: 0)
                                Text(app.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                Text(app.computerName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(12).frame(maxWidth: .infinity, minHeight: 110, maxHeight: .infinity, alignment: .leading)
                            .background(.primary.opacity(scheme == .dark ? 0.055 : 0.035), in: .rect(cornerRadius: 18))
                        }
                        .accessibilityLabel("Open \(app.name) on \(app.computerName)")
                    }
                }
                .privacySensitive()
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(apps.prefix(4)) { app in
                        Link(destination: WidgetLink.app(app.id).url) {
                            VStack(spacing: 8) {
                                WidgetAppArtwork(data: app.artwork, size: 43)
                                Text(app.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .top)
                            .contentShape(.rect)
                        }
                        .accessibilityLabel("Open \(app.name)")
                    }
                    if apps.count < 4 {
                        ForEach(0..<(4 - apps.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                    }
                }
                .privacySensitive()
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.primary)
    }
}

struct AskMindwireWidgetContent: View {
    let snapshot: WidgetAssistantSnapshot
    let date: Date
    var expanded = false

    private var focus: WidgetChatActivity? { snapshot.focus }
    private var stale: Bool { focus?.isStale(at: date) == true }
    private var artwork: Data? { focus.flatMap(snapshot.bot)?.artwork ?? snapshot.artwork }
    private var headline: String {
        guard let focus else { return "What’s on\nyour mind?" }
        switch focus.state {
        case .working: return stale ? "Pick up\nfrom here." : "On it."
        case .approval: return "A quick\napproval."
        case .input: return "Over to you."
        case .finished: return "Ready for you."
        case .failed: return "Let’s take\na look."
        case .stopped: return "Ready when\nyou are."
        }
    }
    private var action: String {
        guard let focus else { return "Ask Mindwire" }
        if stale { return "Open chat" }
        switch focus.state {
        case .approval, .failed: return "Review"
        case .input: return "Reply"
        case .working: return "View progress"
        case .finished: return "See result"
        case .stopped: return "Continue"
        }
    }

    var body: some View {
        Group {
            if expanded {
                HStack(spacing: 16) {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(.primary.opacity(0.08)).frame(width: 1).padding(.vertical, 4)
                    activityPanel.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { summary }
        }
        .foregroundStyle(.primary)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    WidgetAppArtwork(data: artwork, size: 38)
                    if let focus {
                        Image(systemName: focus.state.symbol)
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(WidgetStyle.ink)
                            .frame(width: 17, height: 17).background(WidgetStyle.peach, in: Circle())
                            .overlay(Circle().stroke(.background, lineWidth: 2))
                            .offset(x: 3, y: 1).widgetAccentable()
                    }
                }
                Spacer(minLength: 0)
                if snapshot.attentionCount > 1 {
                    Text("\(snapshot.attentionCount)").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(WidgetStyle.orange.opacity(0.15), in: Capsule())
                } else {
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(headline).font(.system(size: expanded ? 19 : 20, weight: .semibold))
                .tracking(-0.4).lineSpacing(-1).lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
            if let focus {
                Text(expanded ? focus.title : stale ? focus.label(at: date) : snapshot.bot(for: focus)?.name ?? "Mindwire")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
            }
            if expanded {
                Link(destination: snapshot.destination) { actionLabel }
            } else { actionLabel }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(focus?.label(at: date) ?? "Ask Mindwire")
    }

    private var actionLabel: some View {
        HStack(spacing: 4) {
            Text(action).font(.system(size: 11, weight: .semibold))
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(WidgetStyle.orange).lineLimit(1)
        .padding(.top, 2).widgetAccentable()
    }

    private var activityPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Link(destination: WidgetLink.ask.url) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 24)
                }.accessibilityLabel("Open Mindwire assistant")
            }
            if snapshot.activity.isEmpty {
                Text("A little help.\nA lot of possibilities.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
                Spacer(minLength: 0)
                Link(destination: WidgetLink.apps.url) {
                    Label("Your apps", systemImage: "square.grid.2x2").font(.system(size: 11, weight: .medium))
                }
            } else {
                ForEach(snapshot.activity.prefix(2)) { item in
                    Link(destination: WidgetLink.chat(item.chatID).url) {
                        HStack(spacing: 7) {
                            WidgetAppArtwork(data: snapshot.bot(for: item)?.artwork, size: 25)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.bot(for: item)?.name ?? "Mindwire").font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(item.label(at: date)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .privacySensitive()
                    .accessibilityLabel("\(snapshot.bot(for: item)?.name ?? "Mindwire"), \(item.label(at: date)). Open chat.")
                }
                Spacer(minLength: 0)
                if let focus {
                    HStack(spacing: 3) {
                        Text("Updated")
                        Text(focus.observedAt, style: .relative)
                    }.font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}
