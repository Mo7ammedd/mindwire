import SwiftUI

struct MessagingIntegration: Decodable, Identifiable {
    let id: String
    let revision: Int64
    let name: String
    let provider: String
    let botId: String
    let mode: String
    let enabled: Bool
    let channelIds: [String]
    let userIds: [String]?
    let workspaceId: String?
    let applicationId: String?
    let command: String?
    let notify: Bool
    let conditions: [String]?
    let destination: String?
    let serviceUrl: String?
    let webhookPath: String
}

private struct MessagingReceipt: Decodable, Identifiable {
    let id: String
    let state: String
    let error: String?
    let createdAt: String
}

struct BotIntegrationsScreen: View {
    let bot: AssistantBot
    var embedded = false
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var connections: [MessagingIntegration] = []
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var editor: EditorDestination?
    @State private var activity: MessagingIntegration?
    @State private var removing: MessagingIntegration?
    @State private var notice: String?

    private struct EditorDestination: Identifiable {
        let id = UUID()
        let provider: MessagingProvider
        var connection: MessagingIntegration?
    }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .task { await load() }
        .sheet(item: $editor, onDismiss: { Task { await load() } }) {
            MessagingIntegrationSetupScreen(bot: bot, provider: $0.provider, connection: $0.connection)
        }
        .sheet(item: $activity) { MessagingIntegrationActivity(bot: bot, connection: $0) }
        .confirmationDialog("Disconnect this integration?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { if let connection = removing { Task { await disconnect(connection) } } }
        } message: { Text("Your conversations remain available in Mindwire.") }
        .alert("Message sent", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: { Text(notice ?? "") }
        .frame(minWidth: ApplePlatform.isDesktop ? 540 : nil, minHeight: ApplePlatform.isDesktop ? 560 : nil)
    }

    private var content: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(bot.name).font(.headline)
                        Text("Talk to your bot from another app.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            }.listRowBackground(Color.clear)

            if loading && connections.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().chatActivityTint()
                    Text("Loading integrations…").foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("bot.integrations.loading")
            }
            if !connections.isEmpty {
                Section("Added apps") {
                    ForEach(connections) { connection in
                        if let provider = MessagingProvider(rawValue: connection.provider) {
                            HStack(spacing: 12) {
                                Button { editor = .init(provider: provider, connection: connection) } label: {
                                    HStack(spacing: 12) {
                                        MessagingProviderIcon(provider: provider)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(connection.name).fontWeight(.medium).foregroundStyle(.primary)
                                            Text(connection.enabled ? MessagingMode(rawValue: connection.mode)?.title ?? connection.mode : "Paused")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(.rect)
                                }.buttonStyle(.plain)
                                Menu {
                                    Button("Settings", systemImage: "slider.horizontal.3") { editor = .init(provider: provider, connection: connection) }
                                    Button("Delivery activity", systemImage: "clock.arrow.circlepath") { activity = connection }
                                    Button("Send test message", systemImage: "paperplane") { Task { await test(connection) } }
                                        .disabled(!connection.enabled || working)
                                    Divider()
                                    Button("Disconnect", systemImage: "trash", role: .destructive) { removing = connection }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 36, height: 40).contentShape(.rect)
                                }
                                .accessibilityLabel("Manage \(connection.name)")
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            if let error {
                Section {
                    Label("Couldn't reach integrations", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }.disabled(loading)
                }.accessibilityIdentifier("bot.integrations.error")
            }
            Section {
                ForEach(MessagingProvider.allCases) { provider in
                    Button { editor = .init(provider: provider) } label: {
                        HStack(spacing: 14) {
                            MessagingProviderIcon(provider: provider)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.title).fontWeight(.medium).foregroundStyle(.primary)
                                Text(provider.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.padding(.vertical, 5).contentShape(.rect)
                    }
                    .accessibilityIdentifier("bot.integrations.add.\(provider.rawValue)")
                }
            } header: { Text(connections.isEmpty ? "Choose an app" : "Add another app") }
            footer: { Text("Setup requires a bot account in the app you choose and a public HTTPS webhook.") }
        }
        .listStyle(.insetGrouped).tint(.primary)
        .navigationTitle("Integrations").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("bot.integrations.screen")
        .toolbar {
            if !embedded {
                AppToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.tint(.primary) }
            }
        }
        .refreshable { await load() }
    }

    @MainActor private func http() async throws -> DaemonHTTP { try await stores.workspaceData.integrationsHTTP(workspaceId: bot.workspaceId) }
    @MainActor private func load() async {
        loading = true
        defer { loading = false }
        do {
            let all: [MessagingIntegration] = try await http().decode("GET", "/integrations")
            connections = all.filter { $0.botId == bot.id }; error = nil
        } catch { if !error.isRequestCancellation { self.error = error.localizedDescription } }
    }
    @MainActor private func test(_ connection: MessagingIntegration) async {
        guard !working else { return }
        working = true; defer { working = false }
        do {
            let remote = try await http()
            _ = try await remote.run("POST", "/integrations/\(remote.encQuery(connection.id))/send", json: ["text": "\(bot.name) is connected to Mindwire."])
            notice = "Check \(connection.name) for your test message."
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func disconnect(_ connection: MessagingIntegration) async {
        guard !working else { return }
        working = true; defer { working = false }
        do {
            let remote = try await http()
            _ = try await remote.run("DELETE", "/integrations/\(remote.encQuery(connection.id))", json: nil)
            removing = nil; await load()
        } catch { self.error = error.localizedDescription }
    }
}

/// A provider is chosen before opening setup. Saved credentials stay write-only.
struct MessagingIntegrationSetupScreen: View {
    let bot: AssistantBot
    let provider: MessagingProvider
    let connection: MessagingIntegration?
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var mode: MessagingMode
    @State private var enabled: Bool
    @State private var notify: Bool
    @State private var channels: String
    @State private var users: String
    @State private var workspace: String
    @State private var application: String
    @State private var destination: String
    @State private var serviceURL: String
    @State private var command: String
    @State private var token = ""
    @State private var signingSecret = ""
    @State private var webhookSecret = ""
    @State private var publicKey = ""
    @State private var clientSecret = ""
    @State private var saving = false
    @State private var error: String?
    @State private var saved: MessagingIntegration?

    init(bot: AssistantBot, provider: MessagingProvider, connection: MessagingIntegration? = nil) {
        self.bot = bot; self.provider = provider; self.connection = connection
        _name = State(initialValue: connection?.name ?? provider.title)
        _mode = State(initialValue: connection.flatMap { MessagingMode(rawValue: $0.mode) } ?? .chat)
        _enabled = State(initialValue: connection?.enabled ?? true)
        _notify = State(initialValue: connection?.notify ?? false)
        _channels = State(initialValue: connection?.channelIds.joined(separator: ", ") ?? "")
        _users = State(initialValue: connection?.userIds?.joined(separator: ", ") ?? "")
        _workspace = State(initialValue: connection?.workspaceId ?? "")
        _application = State(initialValue: connection?.applicationId ?? "")
        _destination = State(initialValue: connection?.destination ?? "")
        _serviceURL = State(initialValue: connection?.serviceUrl ?? "")
        _command = State(initialValue: connection?.command ?? "/mindwire")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        MessagingProviderIcon(provider: provider, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(saved == nil ? provider.title : "Finish setup").font(.title3.weight(.semibold))
                            Text(saved == nil ? "Connect to \(bot.name)" : "Configuration saved")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }.listRowBackground(Color.clear)
                if let saved {
                    webhookSection(saved)
                } else {
                    credentialsSection
                    accessSection
                    behaviorSection
                    if let connection { webhookSection(connection) }
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled().tint(.primary)
            .scrollDismissesKeyboard(.interactively)
            .disabled(saving)
            .navigationTitle(saved != nil ? "Finish setup" : connection == nil ? "Connect \(provider.title)" : provider.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button(saved != nil ? "Done" : "Cancel") { dismiss() }.tint(.primary)
                }
                if saved == nil {
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : connection == nil ? "Continue" : "Save") { Task { await save() } }
                            .disabled(saving).tint(.primary)
                    }
                }
            }
            .onChange(of: mode) { if mode == .notifications { notify = true } }
            .onChange(of: channels) {
                if !ids(channels).contains(trimmed(destination)) { destination = "" }
            }
            .alert("Check setup", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(saving)
        .frame(minWidth: ApplePlatform.isDesktop ? 540 : nil, minHeight: ApplePlatform.isDesktop ? 600 : nil)
    }

    private var credentialsSection: some View {
        Section {
            if connection == nil {
                Link(destination: provider.portalURL) {
                    Label(provider == .telegram ? "Open BotFather" : "Open \(provider.title) setup", systemImage: "arrow.up.right")
                }
            }
            if provider != .teams { secret("Bot token", text: $token) }
            switch provider {
            case .slack: secret("Signing secret", text: $signingSecret)
            case .telegram:
                secret("Webhook secret", text: $webhookSecret)
                if webhookSecret.isEmpty {
                    Button("Generate webhook secret", systemImage: "key") {
                        webhookSecret = UUID().uuidString + UUID().uuidString
                    }
                }
            case .discord: field("Public key", text: $publicKey, placeholder: "64-character key")
            case .teams: secret("Client secret", text: $clientSecret)
            }
        } header: { Text(connection == nil ? "1. Bot credentials" : "Credentials") }
        footer: {
            Text(connection == nil ? provider.credentialHint : "Leave a credential empty to keep its saved value.")
        }
    }

    private var accessSection: some View {
        Section {
            if provider != .telegram { field(provider.workspaceLabel, text: $workspace) }
            if provider == .discord || provider == .teams { field("Application ID", text: $application) }
            field(provider.channelLabel, text: $channels, placeholder: "Separate multiple IDs with commas")
            if provider == .teams {
                field("Service URL", text: $serviceURL, placeholder: "https://smba.trafficmanager.net/…")
            }
            Link("Where do I find these?", destination: provider.setupURL)
        } header: { Text(connection == nil ? "2. Who can use it" : "Access") }
        footer: { Text("Only the chats or channels you add can use \(bot.name).") }
    }

    private var behaviorSection: some View {
        Section {
            Picker("Use for", selection: $mode) {
                ForEach(MessagingMode.allCases) { Text($0.title).tag($0) }
            }
            DisclosureGroup("More options") {
                field("Name", text: $name)
                Toggle("Enabled", isOn: $enabled)
                Toggle("Send bot updates", isOn: $notify).disabled(mode == .notifications)
                field("Allowed user IDs", text: $users, placeholder: "Optional")
                if notify || mode == .notifications {
                    field("Update destination", text: $destination, placeholder: "First allowed channel")
                }
                if provider == .slack || provider == .discord { field("Slash command", text: $command) }
            }
        } header: { Text(connection == nil ? "3. How it works" : "Behavior") }
        footer: { Text(mode.summary) }
    }

    private func webhookSection(_ connection: MessagingIntegration) -> some View {
        Section {
            Text("Publish this path on your computer’s public HTTPS address, then finish setup in \(provider.title).")
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Webhook path").font(.caption).foregroundStyle(.secondary)
                Text(connection.webhookPath).font(.footnote.monospaced()).textSelection(.enabled)
                Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = connection.webhookPath }
                    .font(.subheadline)
            }.padding(.vertical, 4)
            Text(provider.webhookHint).font(.subheadline)
            if provider == .telegram, !webhookSecret.isEmpty {
                Button("Copy webhook secret", systemImage: "key") { UIPasteboard.general.string = webhookSecret }
            }
            Link("Step-by-step \(provider.title) guide", destination: provider.setupURL)
        } header: { Text("Webhook setup") }
        footer: { Text("A saved configuration still needs this step to receive messages. Keep the management API private.") }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String = "Required") -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(placeholder, text: text).font(.subheadline)
        }.padding(.vertical, 4)
    }
    private func secret(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.medium))
            SecureField(connection == nil ? "Required" : "Saved · leave empty to keep", text: text)
                .font(.subheadline).privacySensitive()
        }.padding(.vertical, 4)
    }
    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func ids(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split { $0 == "," || $0 == "\n" }.map { trimmed(String($0)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private var validationError: String? {
        if ids(channels).isEmpty { return "Add at least one \(provider.channelLabel.lowercased()) entry." }
        if provider != .telegram && trimmed(workspace).isEmpty { return "Enter your \(provider.workspaceLabel.lowercased())." }
        if (provider == .discord || provider == .teams) && trimmed(application).isEmpty { return "Enter the application ID." }
        if provider == .teams && trimmed(serviceURL).isEmpty { return "Enter the Teams service URL from a trusted activity." }
        if connection == nil {
            if provider != .teams && trimmed(token).isEmpty { return "Enter your bot token." }
            if provider == .slack && trimmed(signingSecret).isEmpty { return "Enter the Slack signing secret." }
            if provider == .telegram && trimmed(webhookSecret).isEmpty { return "Generate or enter a webhook secret." }
            if provider == .discord && trimmed(publicKey).isEmpty { return "Enter the application’s public key." }
            if provider == .teams && trimmed(clientSecret).isEmpty { return "Enter your client secret." }
        }
        if !trimmed(destination).isEmpty && !ids(channels).contains(trimmed(destination)) { return "The update destination must be one of your allowed chats or channels." }
        if trimmed(name).utf8.count > 120 { return "Keep the connection name under 120 bytes." }
        return nil
    }

    @MainActor private func save() async {
        guard !saving else { return }
        if let validationError { error = validationError; return }
        error = nil; saving = true; defer { saving = false }
        var credentials: [String: String] = [:]
        for (key, value) in [("botToken", token), ("signingSecret", signingSecret), ("webhookSecret", webhookSecret), ("publicKey", publicKey), ("clientSecret", clientSecret)] where !trimmed(value).isEmpty {
            credentials[key] = trimmed(value)
        }
        var body: [String: Any] = ["name": trimmed(name).isEmpty ? provider.title : trimmed(name), "provider": provider.rawValue,
            "botId": bot.id, "mode": mode.rawValue, "enabled": enabled, "notify": notify,
            "channelIds": ids(channels), "userIds": ids(users), "workspaceId": trimmed(workspace),
            "applicationId": trimmed(application), "destination": trimmed(destination), "serviceUrl": trimmed(serviceURL), "command": trimmed(command)]
        if !credentials.isEmpty { body["credentials"] = credentials }
        if let connection { body["expectedRevision"] = connection.revision }
        if let conditions = connection?.conditions { body["conditions"] = conditions }
        do {
            let http = try await stores.workspaceData.integrationsHTTP(workspaceId: bot.workspaceId)
            let path = connection.map { "/integrations/\(http.encQuery($0.id))" } ?? "/integrations"
            let result: MessagingIntegration = try await http.decode(connection == nil ? "POST" : "PUT", path, json: body)
            if connection == nil { saved = result } else { dismiss() }
        } catch { if !error.isRequestCancellation { self.error = error.localizedDescription } }
    }
}

private struct MessagingIntegrationActivity: View {
    let bot: AssistantBot
    let connection: MessagingIntegration
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var receipts: [MessagingReceipt] = []
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                ForEach(receipts) { receipt in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(receipt.state.capitalized).font(.headline)
                        Text(fmtDate(receipt.createdAt)).font(.caption).foregroundStyle(.secondary)
                        if let error = receipt.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                        if receipt.state == "failed" { Button("Retry delivery") { Task { await retry(receipt) } } }
                    }
                }
                if receipts.isEmpty && error == nil { Text("No messages received yet.").foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            .navigationTitle("Delivery activity").navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(.primary) } }
            .refreshable { await load() }
        }.task { await load() }
    }
    @MainActor private func load() async {
        do {
            let http = try await stores.workspaceData.integrationsHTTP(workspaceId: bot.workspaceId)
            receipts = try await http.decode("GET", "/integrations/\(http.encQuery(connection.id))/events"); error = nil
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func retry(_ receipt: MessagingReceipt) async {
        do {
            let http = try await stores.workspaceData.integrationsHTTP(workspaceId: bot.workspaceId)
            _ = try await http.run("POST", "/integrations/\(http.encQuery(connection.id))/events/\(http.encQuery(receipt.id))/retry", json: [:])
            await load()
        } catch { self.error = error.localizedDescription }
    }
}
