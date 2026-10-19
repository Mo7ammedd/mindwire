import SwiftUI

@MainActor @Observable
final class ChatCommandPickerModel {
    var catalog = DaemonCommandCatalog()
    var loading = false
    var error: String?
    var loaded = false
    private struct Read {
        let id = UUID()
        let session: ObjectIdentifier
        let directory: String?
        let task: Task<DaemonCommandCatalog, Error>
    }
    @ObservationIgnored private var pending: Read?

    func load(session: DaemonSession?, directory: String?, force: Bool = false) async {
        guard let session else { error = t("chat.commands.unavailable"); return }
        let identity = ObjectIdentifier(session)
        let read: Read
        if let current = pending, current.session == identity, current.directory == directory {
            read = current
        } else {
            pending?.task.cancel()
            read = Read(session: identity, directory: directory,
                        task: Task { try await session.commands(directory: directory, force: force) })
            pending = read
        }
        loading = true
        defer { if pending?.id == read.id { pending = nil; loading = false } }
        do {
            let result = try await read.task.value
            guard pending?.id == read.id else { return }
            catalog = result
            error = nil
            loaded = true
        } catch {
            if pending?.id == read.id, !error.isRequestCancellation { self.error = error.localizedDescription }
        }
    }

    func command(_ input: String) -> (DaemonHarnessCommand, DaemonCommandInvocation)? {
        guard let invocation = DaemonCommandInvocation.parse(input),
              let command = catalog.commands.first(where: { $0.isSupported && $0.matches(invocation.name) }) else { return nil }
        return (command, .init(name: command.name, arguments: invocation.arguments))
    }

    func matches(_ query: String) -> [DaemonHarnessCommand] {
        catalog.commands.filter { $0.isSupported && $0.matchesSearch(query) }
    }
}

struct ChatCommandsSheet: View {
    let model: ChatCommandPickerModel
    let running: Bool
    let hasSession: Bool
    var agentType: AgentID?
    let load: (Bool) async -> Void
    let select: (DaemonHarnessCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if let message = model.error ?? model.catalog.warning {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        Button(t("common.retry")) { Task { await load(true) } }.tint(.primary)
                    }
                }
                if model.loading && model.catalog.commands.isEmpty {
                    HStack(spacing: Spacing.md) {
                        AppLogo(size: 24)
                        Text(t("chat.commands.loading")).foregroundStyle(.secondary)
                        Spacer()
                        ProgressView().chatActivityTint().controlSize(.small)
                    }
                } else {
                    let matches = model.matches(search)
                    commandSection(matches.filter { $0.kind != "prompt" }, title: t("chat.commands.controls"))
                    commandSection(matches.filter { $0.kind == "prompt" }, title: t("chat.commands.native"))
                    if matches.isEmpty && model.error == nil {
                        Text(t("chat.commands.noMatches")).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            .navigationTitle(t("chat.commands.title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: t("chat.commands.search"))
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { dismiss() }.tint(.primary) } }
            .task { await load(false) }
            .refreshable { await load(true) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("chat.commands.sheet")
    }

    @ViewBuilder
    private func commandSection(_ commands: [DaemonHarnessCommand], title: String) -> some View {
        if !commands.isEmpty {
            Section {
                ForEach(commands) { command in
                    Button { select(command) } label: { ChatCommandRow(command: command) }
                        .buttonStyle(.plain)
                        .disabled(command.requiresIdle == true && running || command.requiresSession == true && !hasSession)
                        .accessibilityIdentifier("chat.command.\(command.name)")
                }
            } header: { Text(title) } footer: {
                if running && commands.contains(where: { $0.requiresIdle == true }) {
                    Text(t("chat.commands.wait"))
                }
            }
        }
    }
}

struct ChatCommandRow: View {
    let command: DaemonHarnessCommand
    var compact = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(command.label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                if let description = command.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                }
            }
            Spacer(minLength: Spacing.sm)
            Text("/" + command.name).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .padding(.vertical, compact ? 2 : 4)
        .contentShape(Rectangle())
    }
}

struct ChatCompactSheet: View {
    let command: DaemonHarnessCommand
    let chat: ChatModel
    @State var instructions: String = ""
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(t("chat.commands.compactBody")).foregroundStyle(.secondary)
                    if command.acceptsArguments == true {
                        TextField(t("chat.commands.compactInstructions"), text: $instructions, axis: .vertical).lineLimit(2...5)
                    }
                }
                if let error = chat.turnError { Section { ChatErrorDisclosure(title: t("chat.error.title"), detail: error) { chat.turnError = nil } } }
            }
            .navigationTitle(command.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button(t("common.cancel")) { dismiss() }.disabled(working) }
                AppToolbarItem(placement: .confirmationAction) {
                    Button {
                        working = true
                        Task { if await chat.compact(instructions: instructions) { dismiss() }; working = false }
                    } label: {
                        if working { ProgressView().chatActivityTint().controlSize(.small) } else { Text(t("chat.commands.compact")) }
                    }
                    .disabled(working || !chat.canCompact)
                    .accessibilityIdentifier("chat.commands.compact.confirm")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(working)
    }
}
