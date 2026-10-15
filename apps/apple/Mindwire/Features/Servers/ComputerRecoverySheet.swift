import SwiftUI

/// The offline workspace, connection settings, and workspace list share recovery.
/// A route refresh keeps the computer identity and all local project/chat links.
struct ComputerRecoverySheet: View {
    let serverId: String
    var repository: WorkspaceRepository = .shared
    var onConnected: ((Connection) -> Void)? = nil
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = QRScanPresentation()
    @State private var code = ""
    @State private var error: String?
    @State private var attempt = UUID()
    @State private var task: Task<Void, Never>?

    private var connection: Connection? { stores.connections.get(serverId) }
    private var busy: Bool { repository.reconnectingComputers.contains(serverId) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Scan a new code from \(connection?.name ?? "your computer") to repair this connection.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: Spacing.sm) {
                        Text("mindwire connect pair").font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy Command", icon: .copy) {
                            UIPasteboard.general.string = "mindwire connect pair"
                        }.labelStyle(.iconOnly).buttonStyle(.borderless).tint(.secondary)
                    }
                } header: {
                    Text("Run on your computer")
                } footer: {
                    Text("Your projects and saved computer are kept.")
                }

                Section {
                    Button("Scan Connection Code", icon: .scan) {
                        cancelRetry()
                        scanner.present()
                    }
                    .tint(Palette.accent)
                    .accessibilityIdentifier("computer-recovery-scan")
                    DisclosureGroup("Paste a connection link") {
                        TextField("Connection link", text: $code)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.go).onSubmit { reconnect(code: code) }
                        if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Use Connection Link") { reconnect(code: code) }
                                .tint(.primary).disabled(busy)
                        }
                    }
                }

                if busy {
                    Section {
                        HStack(spacing: Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text(repository.computerReconnectMessages[serverId] ?? "Reconnecting…")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button("Cancel Retry", role: .cancel) { cancelRetry() }.tint(.primary)
                    }
                } else {
                    if let error {
                        Section { Text(error).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    Section {
                        Button("Retry Saved Connection", icon: .refresh) { reconnect() }.tint(.primary)
                        NavigationLink("Connection Help") { ComputerSetupHelpScreen() }
                    }
                }
            }
            .navigationTitle("Repair Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(.primary)
                }
            }
        }
        .qrScanner(scanner) { scanned in
            code = scanned
            reconnect(code: scanned)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { task?.cancel() }
    }

    private func cancelRetry() {
        attempt = UUID()
        task?.cancel()
        repository.cancelComputerReconnect(serverId)
    }

    private func reconnect(code: String? = nil) {
        let id = UUID()
        attempt = id
        error = nil
        task?.cancel()
        task = Task {
            do {
                let connection = try await repository.reconnectComputer(serverId, code: code)
                guard !Task.isCancelled, attempt == id else { return }
                onConnected?(connection)
                dismiss()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, attempt == id else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
