import SwiftUI

struct AppsCatalogScreen: View {
    var onCreate: (() -> Void)? = nil
    var creating = false
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @State private var selected: AppShortcut?
    @State private var settings: AppShortcut?
    @State private var removing: AppShortcut?
    @State private var publishing: AppShortcut?
    @State private var error: String?

    private var apps: [AppShortcut] {
        _ = stores.apps.revision
        return stores.apps.list().filter { !$0.archived && WorkspaceRepository.shared.get($0.workspaceId) != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            if ApplePlatform.isDesktop { desktopHeader }
            if apps.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 35, weight: .light))
                        .foregroundStyle(BotColor.brand.fill).frame(width: 88, height: 88)
                        .background(BotColor.brand.fill.opacity(0.09), in: .rect(cornerRadius: 26))
                    VStack(spacing: 8) {
                        Text("Your ideas, ready to open").font(.title3.weight(.semibold))
                        Text("Ask Mindwire to make something for you.").font(.subheadline).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                    if let onCreate {
                        Button("Create an app", action: onCreate).buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule).tint(BotColor.brand.fill).foregroundStyle(BotColor.ink)
                            .disabled(creating)
                    }
                    if creating { ProgressView().chatActivityTint() }
                }
                .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: ApplePlatform.isDesktop ? 160 : 135), spacing: 16)], spacing: 16) {
                        ForEach(apps) { app in
                            Button { selected = app } label: {
                                VStack(spacing: 14) {
                                    AppShortcutIcon(shortcut: app, size: 58)
                                    Text(app.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, minHeight: 134)
                                .padding(12).background(AssistantStyle.surface, in: .rect(cornerRadius: 24))
                                .contentShape(.rect(cornerRadius: 24))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open", systemImage: "arrow.up.right") { selected = app }
                                if let link = app.shareLink {
                                    Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = link }
                                }
                                if app.automation != true {
                                    Button(app.publicLink == nil ? "Publish…" : "Publish Update…", systemImage: "globe") { publishing = app }
                                }
                                Button("Settings", systemImage: "slider.horizontal.3") { settings = app }
                                Divider()
                                Button("Remove from Apps", systemImage: "trash", role: .destructive) { removing = app }
                                    .tint(.red).foregroundStyle(.red)
                            }
                            .tint(.primary)
                            .accessibilityIdentifier("apps.shortcut.\(app.id)")
                        }
                    }
                    .padding(ApplePlatform.isDesktop ? 32 : 20).frame(maxWidth: 900).frame(maxWidth: .infinity)
                }
            }
        }
        .background(ApplePlatform.isDesktop ? AssistantDesktopStyle.canvas : AssistantStyle.canvas)
        .navigationTitle("Apps").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !ApplePlatform.isDesktop, let onCreate {
                AppToolbarItem(placement: .topBarTrailing) {
                    Button(action: onCreate) { Image(systemName: "plus") }.tint(.primary).disabled(creating).accessibilityLabel("Create an app")
                }
            }
        }
        .sheet(item: $selected) { AppShortcutDestination(shortcut: $0) }
        .sheet(item: $settings) { AppShortcutSettings(shortcut: $0) }
        .sheet(item: $publishing) { AppPublishSheet(shortcut: $0) }
        .confirmationDialog("Remove this shortcut?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let app = removing {
                Button("Remove from Apps", role: .destructive) {
                    Task {
                        do { try await stores.workspaceData.editApp(app, edit: .init(expectedRevision: app.revision, archived: true)) }
                        catch { self.error = error.localizedDescription }
                        removing = nil
                    }
                }
            }
        }
        .alert("Couldn’t update app", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task { await stores.workspaceData.refreshAll(WorkspaceRepository.shared.all) }
        .refreshable { await stores.workspaceData.refreshAll(WorkspaceRepository.shared.all, force: true) }
    }

    private var desktopHeader: some View {
        HStack(spacing: 10) {
            if !app.desktopNavigationVisible && !app.desktopBotRailVisible { DesktopNavigationToggle() }
            Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            Text("Apps").font(.system(size: 15, weight: .semibold))
            Spacer()
            if let onCreate { Button("Create an app", action: onCreate).buttonStyle(.bordered).controlSize(.regular).disabled(creating) }
        }
        .padding(.horizontal, AssistantDesktopStyle.gutter).frame(height: AssistantDesktopStyle.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(AssistantDesktopStyle.separator).frame(height: 0.5) }
    }
}


struct AppShortcutChatCard: View {
    let shortcut: AppShortcut
    let workspaceId: String?
    var publishing = false
    @Environment(\.stores) private var stores
    @State private var selected: AppShortcut?

    private var current: AppShortcut {
        _ = stores.apps.revision
        return stores.apps.get(shortcut.id) ?? shortcut
    }

    private var resolved: AppShortcut {
        var app = current
        if WorkspaceRepository.shared.get(app.workspaceId) != nil { return app }
        if let local = WorkspaceRepository.shared.all.first(where: { stores.workspaceData.identity(workspaceId: $0.id) == shortcut.workspaceId }) {
            app.workspaceId = local.id
        } else if let workspaceId, WorkspaceRepository.shared.get(workspaceId) != nil,
                  shortcut.workspaceId.isEmpty || stores.workspaceData.identity(workspaceId: workspaceId) == shortcut.workspaceId {
            app.workspaceId = workspaceId
        }
        return app
    }

    var body: some View {
        Button { selected = resolved } label: {
            HStack(spacing: 14) {
                AppShortcutIcon(shortcut: current)
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(current.archived ? "Removed from Apps" : publishing ? (current.publicLink == nil ? "Ready to publish" : "Public link ready") : "Saved to Apps").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Label(publishing ? (WorkspaceRepository.shared.get(resolved.workspaceId)?.runtime.isCloud == true ? "Publish" : "Mindwire Cloud") : "Open", systemImage: publishing ? "globe" : "arrow.up.right")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            }.padding(16).background(AssistantStyle.surface, in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain).disabled(current.archived).accessibilityIdentifier("apps.chat.open.\(shortcut.id)")
        .sheet(item: $selected) { value in
            if publishing { AppPublishSheet(shortcut: value) }
            else { AppShortcutDestination(shortcut: value) }
        }
        .task(id: shortcut.revision) {
            guard (stores.apps.get(shortcut.id)?.revision ?? 0) < shortcut.revision else { return }
            if let workspace = WorkspaceRepository.shared.get(resolved.workspaceId) { await stores.workspaceData.refresh(workspace) }
        }
    }
}

struct AppPublishChatCard: View {
    let shortcut: AppShortcut
    let workspaceId: String?
    var body: some View { AppShortcutChatCard(shortcut: shortcut, workspaceId: workspaceId, publishing: true) }
}
