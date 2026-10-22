import SwiftUI

/// One entry point for adding a computer. Pairing, SSH verification and cloud purchases
/// stay in their existing screens; this view only chooses and presents the destination.
struct AddComputerScreen: View {
    var repository: WorkspaceRepository = .shared
    var onCreated: (Workspace) -> Void = { _ in }
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Destination] = []
    @State private var detent: PresentationDetent = .medium
    @State private var adoption: Task<Void, Never>?
    @State private var error: String?

    private enum Destination: String, CaseIterable, Identifiable {
        case computer, ssh, cloud
        var id: Self { self }
        var title: String {
            switch self {
            case .computer: "Connect a computer"
            case .ssh: "Connect via SSH"
            case .cloud: t("assistant.setup.cloud")
            }
        }
        var detail: String {
            switch self {
            case .computer: "Pair your Mac or PC"
            case .ssh: "Use an SSH key or password"
            case .cloud: "A computer that stays online"
            }
        }
        var icon: AppIconName {
            switch self { case .computer: .laptop; case .ssh: .terminal; case .cloud: .cloud }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Destination.allCases) { destination in
                        NavigationLink(value: destination) {
                            HStack(spacing: 14) {
                                AppIcon(destination.icon, size: 24, decorative: true)
                                    .foregroundStyle(Palette.accent)
                                    .frame(width: 48, height: 48)
                                    .background(Palette.accentSoft, in: .rect(cornerRadius: 15))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(destination.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(destination.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                AppIcon(.chevronRight, size: 14, decorative: true).foregroundStyle(.tertiary)
                            }
                            .padding(16)
                            .background(Palette.surface, in: .rect(cornerRadius: 22))
                            .contentShape(.rect(cornerRadius: 22))
                        }
                        .buttonStyle(AssistantPressStyle())
                        .accessibilityIdentifier("computers.add.\(destination.rawValue)")
                    }
                }
                .padding(20)
                .frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Palette.bg)
            .navigationTitle(t("workspaces.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if path.isEmpty {
                    AppToolbarItem(placement: .cancellationAction) {
                        Button(t("common.cancel")) { dismiss() }.tint(.primary)
                    }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .computer, .ssh:
                    AddServerScreen(presetType: destination == .computer ? .local : .ssh,
                                    embedded: true, onSaved: connected)
                case .cloud:
                    NewWorkspaceScreen(assistantCloud: true, embedded: true, onCreated: finish)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: path) { _, value in detent = value.isEmpty ? .medium : .large }
        .alert("Couldn’t finish setup", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t("common.ok"), role: .cancel) {}
        } message: { Text(error ?? "") }
        .onDisappear { adoption?.cancel(); adoption = nil }
    }

    private func connected(_ connection: Connection) {
        guard adoption == nil else { return }
        // Pairing already creates its computer. SSH uses the same adoption path as the
        // existing workspace wizard, which deduplicates the host and queues service setup.
        if let workspace = stores.workspaces(forServerId: connection.id).first(where: { $0.runtime.sandbox == nil }) {
            finish(workspace)
            return
        }
        adoption = Task {
            defer { adoption = nil }
            guard let workspace = await repository.adopt(name: connection.name,
                runtime: .server(serverId: connection.id), spec: nil) else {
                error = "The connection was saved. Open Computers to finish setting it up."
                return
            }
            guard !Task.isCancelled else { return }
            finish(workspace)
        }
    }

    private func finish(_ workspace: Workspace) {
        onCreated(workspace)
        dismiss()
    }
}
