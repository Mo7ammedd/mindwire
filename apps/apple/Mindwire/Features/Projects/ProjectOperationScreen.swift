import SwiftUI

/// A reconnectable view of work owned by the workspace daemon.
struct ProjectOperationScreen: View {
    let reference: ProjectOperationReference
    var repository: WorkspaceRepository = .shared
    @Environment(\.stores) private var stores
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var actions = WorkspaceActions()
    @State private var watchGeneration = 0
    @State private var accountID = ""
    @State private var confirmStop = false
    @State private var connectionError: String?

    private struct ObservationKey: Hashable {
        let generation: Int
        let hasWorkspace: Bool
    }

    private var operation: ProjectOperation? {
        stores.workspaceData.cachedProjectOperation(reference.operationId, workspaceId: reference.workspaceId)
    }
    private var accounts: [GitHubAccount] {
        stores.github.list().filter { account in
            if let connection = operation?.gitConnection, connection.id != account.id { return false }
            switch operation?.authKind {
            case "token": return account.mode == .token || account.mode == .oblienApp
            case "ssh": return account.mode == .sshKey
            default: return false
            }
        }
    }

    private var requiresDeviceAuth: Bool {
        ["token", "ssh"].contains(operation?.authKind ?? "") && operation?.gitConnection?.lifetime != .workspace
    }

    var body: some View {
        NavigationStack {
            Group {
                if repository.get(reference.workspaceId) == nil {
                    WorkspaceUnavailableView(workspaceId: reference.workspaceId, repository: repository)
                } else {
                    operationForm
                }
            }
            .navigationTitle(t("project.operation.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button(t("common.done")) { dismiss() } } }
            .workspaceActionAlerts(actions)
            .alert(t("project.operation.stopConfirm"), isPresented: $confirmStop) {
                Button(t("project.operation.stop"), role: .destructive) {
                    actions.run { try await stores.workspaceData.cancelProjectOperation(reference.operationId, workspaceId: reference.workspaceId) }
                }
                Button(t("common.cancel"), role: .cancel) {}
            }
            .task(id: ObservationKey(generation: watchGeneration, hasWorkspace: repository.get(reference.workspaceId) != nil)) {
                if accountID.isEmpty, let id = operation?.gitConnection?.id, accounts.contains(where: { $0.id == id }) { accountID = id }
                await repository.refreshIfNeeded()
                guard !Task.isCancelled, repository.get(reference.workspaceId) != nil else { return }
                connectionError = nil
                do {
                    let result = try await stores.workspaceData.observeProject(reference.operationId, workspaceId: reference.workspaceId) { _ in }
                    if result.status == "succeeded" && !result.removesFiles { _ = try await stores.workspaceData.projectResult(result, workspaceId: reference.workspaceId) }
                } catch is CancellationError {
                } catch { connectionError = error.localizedDescription }
            }
            .onAppear { if accounts.count == 1 { accountID = accounts[0].id } }
        }
    }

    private var operationForm: some View {
        Form {
            if let operation {
                Section {
                    LabeledContent(t("newProject.section.name"), value: operation.name)
                    Text(operation.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let repo = operation.repoUrl { Text(repo).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Section {
                    if operation.isActive {
                        if let progress = operation.progress { ProgressView(value: progress) }
                        else { ProgressView().progressViewStyle(.linear) }
                    }
                    Text(operation.phaseLabel).foregroundStyle(.secondary)
                    if let error = operation.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let error = connectionError ?? stores.workspaceData.projectObservationErrors[reference.workspaceId] {
                        Label(t("project.operation.reconnecting"), icon: .wifiOff).foregroundStyle(.secondary)
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    if operation.isActive {
                        if operation.canStop {
                            Button(t("project.operation.stop"), role: .destructive) { confirmStop = true }
                        }
                    } else if operation.canRetry {
                        if ["token", "ssh"].contains(operation.authKind ?? "") {
                            Picker(t("project.operation.account"), selection: $accountID) {
                                Text(t("project.operation.chooseAccount")).tag("")
                                ForEach(accounts) { Text($0.connectionLabel).tag($0.id) }
                            }
                        }
                        Button(t("common.retry")) { retry(operation) }
                            .disabled(requiresDeviceAuth && accountID.isEmpty)
                    } else if operation.status == "succeeded" && !operation.removesFiles {
                        Button(t("project.operation.open")) {
                            actions.run {
                                let project = try await stores.workspaceData.projectResult(operation, workspaceId: reference.workspaceId)
                                dismiss(); app.openProject(project.id)
                            }
                        }
                    }
                }
                if let log = operation.log, !log.isEmpty {
                    Section {
                        DisclosureGroup(t("project.clone.showLogs")) {
                            Text(log).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            } else {
                ProgressView()
                if let connectionError { Text(connectionError).foregroundStyle(.secondary) }
            }
        }
    }

    private func retry(_ operation: ProjectOperation) {
        actions.run {
            var auth: ProjectCloneAuth?
            if ["token", "ssh"].contains(operation.authKind ?? "") && (requiresDeviceAuth || !accountID.isEmpty) {
                guard let account = accounts.first(where: { $0.id == accountID }),
                      let url = operation.repoUrl, let repo = GitHubRepo.fromGitInput(url) else {
                    throw BackendError.message(t("project.operation.chooseAccount"))
                }
                auth = try await BackendFactory.githubService(for: account, stores: stores).cloneAuth(repo: repo, account: account)
            }
            try await stores.workspaceData.retryProjectOperation(operation.id, workspaceId: reference.workspaceId, auth: auth)
            connectionError = nil
            watchGeneration += 1
        }
    }
}
