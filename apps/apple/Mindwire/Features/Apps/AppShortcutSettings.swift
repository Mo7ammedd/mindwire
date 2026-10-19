import SwiftUI

struct AppShortcutDestination: View {
    let shortcut: AppShortcut
    var body: some View {
        if shortcut.automation == true { AppShortcutSettings(shortcut: shortcut) }
        else { AppShortcutBrowser(shortcut: shortcut) }
    }
}

/// General settings show delivery and schedules, while scripts and credentials stay on the computer.
struct AppShortcutSettings: View {
    let shortcut: AppShortcut
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var schedules: [AppSchedule] = []
    @State private var channels: [AppNotificationChannel] = []
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var publishing = false

    private var current: AppShortcut { _ = stores.apps.revision; return stores.apps.get(shortcut.id) ?? shortcut }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        AppShortcutIcon(shortcut: current, size: 50)
                        Text(current.name).font(.headline)
                    }.padding(.vertical, 8)
                }
                if current.automation != true {
                    Section("Sharing") {
                        if let link = current.shareLink {
                            Button { UIPasteboard.general.url = link } label: { Label("Copy Link", systemImage: "link") }.tint(.primary)
                        }
                        Button { publishing = true } label: {
                            Label(current.publicLink == nil ? "Publish app…" : "Publish update…", systemImage: "globe")
                        }.tint(.primary)
                    }
                }
                Section("Notifications") {
                    Toggle("Allow notifications", isOn: Binding(get: { current.notificationsMuted != true }, set: { allowed in
                        update {
                            let selected = current.channelIds?.isEmpty == false ? current.channelIds : channels.first.map { [$0.id] }
                            try await stores.workspaceData.editApp(current, edit: .init(expectedRevision: current.revision, channelIds: selected, notificationsMuted: !allowed))
                        }
                    }))
                    .tint(BotColor.brand.fill)
                    .disabled(channels.isEmpty)
                    if !channels.isEmpty {
                        ForEach(channels) { channel in
                            Toggle(channel.name.isEmpty ? "Mindwire" : channel.name, isOn: Binding(
                                get: { (current.channelIds ?? ["mindwire"]).contains(channel.id) },
                                set: { selected in
                                    var ids = current.channelIds ?? ["mindwire"]
                                    if selected { if !ids.contains(channel.id) { ids.append(channel.id) } }
                                    else { ids.removeAll { $0 == channel.id } }
                                    update { try await stores.workspaceData.editApp(current, edit: .init(expectedRevision: current.revision, channelIds: ids, notificationsMuted: ids.isEmpty)) }
                                }))
                                .tint(BotColor.brand.fill)
                        }
                    } else if !loading {
                        NavigationLink("Set up notifications") { NotificationSettingsScreen() }.tint(.primary)
                    }
                }
                Section {
                    if loading { ProgressView().chatActivityTint() }
                    else if schedules.isEmpty {
                        Text("Ask Mindwire to add a reminder or a schedule.").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(schedules) { schedule in
                            VStack(alignment: .leading, spacing: 5) {
                                Toggle(schedule.name, isOn: Binding(get: { schedule.active }, set: { enabled in set(schedule, enabled: enabled) }))
                                    .tint(BotColor.brand.fill).disabled(schedule.state == "running")
                                if schedule.active, let next = schedule.retryAt ?? schedule.nextRunAt, let date = RelativeTime.date(next) {
                                    Text("Next: \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let error = schedule.lastError, !error.isEmpty {
                                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                } else if schedule.state == "running" {
                                    Label("Running", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contextMenu {
                                Button("Delete schedule", systemImage: "trash", role: .destructive) { remove(schedule) }
                            }
                        }
                    }
                } header: { Text("Schedules") } footer: {
                    Text("Runs on its computer, even when your phone is offline.")
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("Retry") { Task { await load() } }.tint(.primary)
                    }
                }
            }
            .formStyle(.grouped).disabled(working)
            .navigationTitle(current.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(.primary) } }
        }
        .task { await load() }.refreshable { await load() }
        .frame(minWidth: ApplePlatform.isDesktop ? 480 : nil, minHeight: ApplePlatform.isDesktop ? 440 : nil)
        .sheet(isPresented: $publishing) { AppPublishSheet(shortcut: current) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let http = try await stores.workspaceData.appAutomationHTTP(workspaceId: shortcut.workspaceId)
            async let saved: [AppSchedule] = http.decode("GET", "/apps/\(http.encQuery(shortcut.id))/schedules", quiet: true)
            async let destinations: [AppNotificationChannel] = http.decode("GET", "/apps/channels", quiet: true)
            (schedules, channels) = try await (saved, destinations)
            error = nil
        } catch { if !error.isRequestCancellation { self.error = error.localizedDescription } }
    }

    private func update(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true
        Task {
            defer { working = false }
            do { try await action(); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }

    private func set(_ schedule: AppSchedule, enabled: Bool) {
        update {
            let http = try await stores.workspaceData.appAutomationHTTP(workspaceId: shortcut.workspaceId)
            let _: AppSchedule = try await http.decode("POST", "/apps/\(http.encQuery(shortcut.id))/schedules", json: schedule.edit(enabled: enabled))
            await load()
        }
    }
    private func remove(_ schedule: AppSchedule) {
        update {
            let http = try await stores.workspaceData.appAutomationHTTP(workspaceId: shortcut.workspaceId)
            _ = try await http.run("DELETE", "/apps/\(http.encQuery(shortcut.id))/schedules/\(http.encQuery(schedule.id))", json: nil)
            await load()
        }
    }
}
