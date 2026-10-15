import SwiftUI

struct WorkspaceWorkloadsScreen: View {
    let model: WorkspaceManagementModel
    @State private var create = false
    @State private var confirmation: WorkspaceConfirmation?

    var body: some View {
        WorkspaceControlPage(title: "Workloads", model: model, feature: .workloads,
                             additionalRefresh: { model.workloadActivity.reconnect() }) {
            Section {
                WorkspaceControlReadState(state: model.workloads)
                ForEach(model.workloads.value ?? []) { workload in
                    let metrics = model.workloadActivity.value(for: workload.id)
                    let state = metrics?.state ?? workload.currentState
                    let running = state == "running"
                    NavigationLink { WorkspaceWorkloadDetailScreen(model: model, initial: workload) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(workload.displayName).lineLimit(1)
                                Spacer()
                                Text(WorkspaceControlFormat.status(state)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(workload.command?.joined(separator: " ") ?? "Managed process").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            if running, let metrics, metrics.cpuLabel != nil || metrics.memoryLabel != nil {
                                Text([metrics.cpuLabel.map { "CPU \($0)" }, metrics.memoryLabel].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .appContextMenu {
                        Button(running ? "Stop" : "Start", icon: running ? .stop : .play) {
                            if running {
                                confirmation = WorkspaceConfirmation(title: "Stop “\(workload.displayName)” ?", message: "This process will stop. You can start it again from Workloads.", actionTitle: "Stop") {
                                    await model.execute(.workload(id: workload.id, action: .stop), title: "Stopping workload…", refresh: [.workloads])
                                }
                            } else { Task { await model.execute(.workload(id: workload.id, action: .start), title: "Starting workload…", refresh: [.workloads]) } }
                        }.disabled(model.isBusy)
                    }
                }
                if model.workloads.loaded, model.workloads.value?.isEmpty == true {
                    WorkspaceControlEmptyState(title: "No workloads", description: "Run a server or background process independently of an open terminal.")
                }
            }
        }
        .toolbar {
            AppToolbarItem(placement: .topBarTrailing) { Button("Create Workload", icon: .plus) { create = true }.tint(.primary).disabled(model.isBusy) }
        }
        .sheet(isPresented: $create) { WorkspaceWorkloadEditor(model: model) }
        .workloadActivity(model.workloadActivity, enabled: model.workloads.value?.isEmpty == false)
        .workspaceConfirmation($confirmation)
    }
}

private struct WorkspaceWorkloadDetailScreen: View {
    let model: WorkspaceManagementModel
    let initial: WorkspaceManagedWorkload
    @State private var confirmation: WorkspaceConfirmation?
    @State private var settings = false
    @Environment(\.dismiss) private var dismiss
    private var workload: WorkspaceManagedWorkload { model.workloads.value?.first { $0.id == initial.id } ?? initial }
    private var metrics: WorkspaceWorkloadMetrics? { model.workloadActivity.value(for: workload.id) }
    private var state: String { metrics?.state ?? workload.currentState }

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: WorkspaceControlFormat.status(state))
                if let pid = metrics?.pid ?? workload.pid, pid > 0 { LabeledContent("Process ID", value: "\(pid)") }
                if let target = workload.target { LabeledContent("Runtime", value: target) }
                if let policy = workload.restartPolicy { LabeledContent("Restart Policy", value: policy.replacingOccurrences(of: "-", with: " ").capitalized) }
                if let count = workload.restartCount { LabeledContent("Restarts", value: "\(count)") }
                if let exit = workload.exitCode { LabeledContent("Exit Code", value: "\(exit)") }
            }
            Section("Command") {
                Text(workload.command?.joined(separator: " ") ?? "—").font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                if let directory = workload.workingDirectory { LabeledContent("Directory", value: directory) }
            }
            if state == "running" {
                Section {
                    LabeledContent("CPU", value: metrics?.cpuLabel ?? "—")
                    LabeledContent("Memory", value: metrics?.memoryLabel ?? "—")
                    if let uptime = metrics?.uptimeLabel { LabeledContent("Uptime", value: uptime) }
                    if let ports = metrics?.ports, !ports.isEmpty { LabeledContent("Ports", value: ports.map(String.init).joined(separator: ", ")) }
                } header: { Text("Live Usage") } footer: {
                    if let error = model.workloadActivity.error { Text(error) }
                }
            }
            Section {
                NavigationLink { WorkspaceLogsScreen(model: model, source: .workload(workload.id), title: workload.displayName) }
                    label: { Label("Logs", icon: .alignLeft) }
                Button("Workload Settings", icon: .sliders) { settings = true }
                if state == "running" {
                    Button("Stop Workload") {
                        confirmation = WorkspaceConfirmation(title: "Stop “\(workload.displayName)” ?", message: "This process will stop. Its configuration and logs are kept.", actionTitle: "Stop") {
                            await model.execute(.workload(id: workload.id, action: .stop), title: "Stopping workload…", refresh: [.workloads])
                        }
                    }
                } else {
                    Button("Start Workload") { Task { await model.execute(.workload(id: workload.id, action: .start), title: "Starting workload…", refresh: [.workloads]) } }
                }
            }.disabled(model.isBusy).tint(.primary)
            Section {
                Button("Delete Workload", role: .destructive) {
                    confirmation = WorkspaceConfirmation(title: "Delete “\(workload.displayName)” ?", message: "The process will stop and its saved workload configuration will be removed.", actionTitle: "Delete", destructive: true) {
                        if await model.execute(.workload(id: workload.id, action: .delete), title: "Deleting workload…", refresh: [.workloads]) != nil { dismiss() }
                    }
                }.disabled(model.isBusy)
            }
            WorkspaceControlFeedback(model: model)
        }
        .navigationTitle(workload.displayName).navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(.workloads, force: true); model.workloadActivity.reconnect() }
        .workloadActivity(model.workloadActivity)
        .sheet(isPresented: $settings) { WorkspaceWorkloadSettingsEditor(model: model, workload: workload) }
        .workspaceConfirmation($confirmation)
    }
}

private struct WorkspaceWorkloadEditor: View {
    let model: WorkspaceManagementModel
    @State private var draft = WorkspaceWorkloadDraft()
    var body: some View {
        WorkspaceControlEditor(title: "Create Workload", model: model, saveTitle: "Create", canSave: !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, save: {
            await model.execute(.createWorkload(draft), title: "Creating workload…", refresh: [.workloads]) != nil
        }) {
            Section {
                TextField("Name (optional)", text: $draft.name)
                TextField("Command", text: $draft.command, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(2...5)
                TextField("Working directory (optional)", text: $draft.directory).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: { Text("Enter the command as you would in a terminal. The workspace keeps it running after this page closes.") }
            Section {
                Picker("Run In", selection: $draft.target) {
                    Text(model.workloadTargets.value?.first(where: \.isDefault).map { "Default (\($0.label))" } ?? "Image Default").tag("")
                    ForEach(model.workloadTargets.value ?? []) { target in
                        Text(target.available ? target.label : "\(target.label) (Unavailable)").tag(target.id).disabled(!target.available)
                    }
                }
            } footer: {
                if let error = model.workloadTargets.error { Text(error) }
            }
            Section("Environment") {
                ForEach($draft.environment) { $variable in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        TextField("Name", text: $variable.key).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Value", text: $variable.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }.onDelete { draft.environment.remove(atOffsets: $0) }
                Button("Add Variable", icon: .plus) { draft.environment.append(.init()) }.tint(.primary)
            }
            Section {
                WorkspaceWorkloadPolicyFields(policy: $draft.restartPolicy, maximum: $draft.maxRestarts)
                DisclosureGroup("Log Retention") {
                    Stepper("File size: \(draft.maxLogSizeMb) MiB", value: $draft.maxLogSizeMb, in: 1...64)
                    Stepper("Keep for \(draft.logRetentionHours) hours", value: $draft.logRetentionHours, in: 1...720)
                }
            }
        }
        .task { await model.loadWorkloadTargets() }
    }
}

private struct WorkspaceWorkloadPolicyFields: View {
    @Binding var policy: String
    @Binding var maximum: Int
    var body: some View {
        Picker("Restart Policy", selection: $policy) {
            Text("Never").tag("never"); Text("On Failure").tag("on-failure"); Text("Always").tag("always")
        }
        if policy != "never" {
            Stepper(maximum == 0 ? "Unlimited restarts" : "Max restarts: \(maximum)", value: $maximum, in: 0...100)
        }
    }
}

private struct WorkspaceWorkloadSettingsEditor: View {
    let model: WorkspaceManagementModel
    let workload: WorkspaceManagedWorkload
    @State private var name: String
    @State private var policy: String
    @State private var maximum: Int
    init(model: WorkspaceManagementModel, workload: WorkspaceManagedWorkload) {
        self.model = model; self.workload = workload
        _name = State(initialValue: workload.name ?? "")
        _policy = State(initialValue: workload.restartPolicy ?? "never")
        _maximum = State(initialValue: workload.maxRestarts ?? 0)
    }
    var body: some View {
        WorkspaceControlEditor(title: "Workload Settings", model: model, save: {
            await model.execute(.updateWorkload(id: workload.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                               restartPolicy: policy, maxRestarts: maximum),
                                title: "Saving workload…", refresh: [.workloads]) != nil
        }) {
            Section { TextField("Name", text: $name) }
            Section {
                WorkspaceWorkloadPolicyFields(policy: $policy, maximum: $maximum)
            } footer: { Text("The policy applies to future exits. Use Stop and Start to restart this process now.") }
        }
    }
}

struct WorkspaceLogsScreen: View {
    let model: WorkspaceManagementModel
    let source: WorkspaceLogSource
    let title: String
    @State private var logs: WorkspaceLogsModel
    @State private var retention = false
    @State private var confirmation: WorkspaceConfirmation?
    @State private var follow = true
    @Environment(\.scenePhase) private var scenePhase
    init(model: WorkspaceManagementModel, source: WorkspaceLogSource, title: String) {
        self.model = model; self.source = source; self.title = title
        _logs = State(initialValue: WorkspaceLogsModel(service: model.service, source: source))
    }
    var body: some View {
        ScrollViewReader { reader in
            List {
                if let error = logs.error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
                Section {
                    ForEach(logs.entries) { entry in
                        Text(entry.line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .listRowSeparator(.hidden).id(entry.id)
                    }
                    if logs.entries.isEmpty { Text("No output yet").foregroundStyle(.secondary) }
                }
                WorkspaceControlFeedback(model: model)
            }
            .onChange(of: logs.entries.last?.id) { _, id in if follow, let id { reader.scrollTo(id, anchor: .bottom) } }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            AppToolbarItem(placement: .topBarTrailing) {
                Button(follow ? "Pause Logs" : "Follow Logs", icon: follow ? .pause : .play) {
                    follow.toggle(); if follow { logs.start() } else { logs.stop() }
                }.tint(.primary)
            }
            if case .workload(let id) = source {
                AppToolbarItem(placement: .topBarTrailing) {
                    AppMenu {
                        Button("Log Retention", icon: .clock) { retention = true }
                        DestructiveButton("Clear Stored Logs", icon: .trash) {
                            confirmation = WorkspaceConfirmation(title: "Clear Stored Logs?", message: "Retained output will be deleted. The workload keeps running.", actionTitle: "Clear", destructive: true) {
                                if await model.execute(.clearLogs(id), title: "Clearing logs…") != nil {
                                    logs.clear(); logs.stop(); if follow { logs.start() }
                                }
                            }
                        }
                    } label: { AppIcon(.more).tint(.primary) }.disabled(model.isBusy)
                }
            }
        }
        .task { if follow { logs.start() } }
        .onDisappear { logs.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, follow { logs.start() } else if phase == .background { logs.stop() }
        }
        .sheet(isPresented: $retention) { if case .workload(let id) = source { WorkspaceLogRetentionEditor(model: model, id: id) } }
        .workspaceConfirmation($confirmation)
    }
}

private struct WorkspaceLogRetentionEditor: View {
    let model: WorkspaceManagementModel
    let id: String
    @State private var config = WorkspaceControlValue<WorkspaceLogConfig>()
    @State private var size = "10"
    @State private var hours = "168"
    var body: some View {
        WorkspaceControlEditor(title: "Log Retention", model: model, canSave: config.loaded && (1...64).contains(Int(size) ?? 0) && (1...720).contains(Int(hours) ?? 0), save: {
            await model.execute(.logRetention(id: id, sizeMb: Int(size) ?? 10, hours: Int(hours) ?? 168), title: "Saving retention…") != nil
        }) {
            Section {
                WorkspaceControlReadState(state: config)
                LabeledContent("File Size (MiB)") { TextField("10", text: $size).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                LabeledContent("Keep For (hours)") { TextField("168", text: $hours).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
            } footer: { Text("Two files are retained. Reducing limits can remove older output immediately. The workload does not restart.") }
        }
        .task {
            await config.load { try await model.service.logConfig(id) }
            if let value = config.value { size = String(value.maxLogSizeMb ?? 10); hours = String(value.logRetentionHours ?? 168) }
        }
    }
}
