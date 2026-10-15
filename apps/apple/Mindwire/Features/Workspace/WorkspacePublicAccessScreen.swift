import SwiftUI

struct WorkspacePublicAccessScreen: View {
    let model: WorkspaceManagementModel
    @State private var newPort = false
    @State private var selectedPort: ExposedPort?
    @State private var editDomain = false
    @State private var editIdle = false
    @State private var confirmation: WorkspaceConfirmation?

    var body: some View {
        WorkspaceControlPage(title: "Public Access", model: model, feature: .publicAccess) {
            Section {
                WorkspaceControlReadState(state: model.network)
                if let network = model.network.value {
                    Toggle("Public Access", isOn: Binding(get: { network.publicAccess == true }, set: { enabled in
                        if enabled { Task { await setAccess(true) } }
                        else {
                            confirmation = WorkspaceConfirmation(title: "Disable Public Access?", message: "Public links and external runtime connections will stop working until access is enabled again.", actionTitle: "Disable") { await setAccess(false) }
                        }
                    })).disabled(model.isBusy)
                }
            }
            Section("Public Links") {
                WorkspaceControlReadState(state: model.ports)
                ForEach(model.ports.value ?? []) { port in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(port.label?.isEmpty == false ? port.label! : "Port \(port.port)")
                            if let url = URL(string: port.url), ["https", "http"].contains(url.scheme) {
                                Link(url.host() ?? port.url, destination: url).font(.subheadline)
                            }
                        }
                        Spacer()
                        AppMenu {
                            if let url = URL(string: port.url), ["https", "http"].contains(url.scheme) { ShareLink(item: url) }
                            Button("Copy Link", icon: .copy) { UIPasteboard.general.string = port.url }
                            Button("Edit Slug", icon: .edit) { selectedPort = port }
                            DestructiveButton("Remove Public Link", icon: .trash) {
                                confirmation = WorkspaceConfirmation(title: "Remove Public Link?", message: "The public URL for port \(port.port) will stop working. Its process keeps running.", actionTitle: "Remove", destructive: true) {
                                    await model.execute(.revokePort(port.port), title: "Removing link…", refresh: [.publicAccess])
                                }
                            }
                        } label: { AppIcon(.more).tint(.primary).padding(.vertical, 8) }.disabled(model.isBusy)
                    }
                }
                if model.ports.loaded, model.ports.value?.isEmpty == true {
                    Text("No ports exposed").foregroundStyle(.secondary)
                }
                Button("Expose Port", icon: .plus) { newPort = true }.disabled(model.isBusy || (model.ports.value?.count ?? 0) >= 20)
            }
            Section("Custom Domain") {
                WorkspaceControlReadState(state: model.domain)
                if let domain = model.domain.value ?? nil, let host = domain.customDomain {
                    LabeledContent("Domain", value: host)
                    if let port = domain.port { LabeledContent("Port", value: "\(port)") }
                    LabeledContent("HTTPS", value: WorkspaceControlFormat.status(domain.sslStatus))
                    if let expiry = domain.sslExpiry { LabeledContent("Certificate Expires", value: expiry) }
                    if let error = domain.sslError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    Button("Edit Domain") { editDomain = true }.disabled(model.isBusy)
                    Button("Renew Certificate") { Task { await model.execute(.renewSSL, title: "Renewing certificate…", refresh: [.publicAccess]) } }.disabled(model.isBusy)
                    Button("Remove Domain", role: .destructive) {
                        confirmation = WorkspaceConfirmation(title: "Remove Domain?", message: "\(host) will no longer route to this workspace.", actionTitle: "Remove", destructive: true) {
                            await model.execute(.removeDomain, title: "Removing domain…", refresh: [.publicAccess])
                        }
                    }.disabled(model.isBusy)
                } else {
                    Button("Connect Domain") { editDomain = true }.disabled(model.isBusy || !model.domain.loaded)
                }
            }
            Section {
                Button { editIdle = true } label: {
                    HStack {
                        LabeledContent("Sleep When Idle", value: (model.lifecycle.value?.idle?.sleepSeconds ?? 0) > 0 ? "Enabled" : "Off")
                        AppIcon(Icon.chevron).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.tint(.primary).disabled(model.isBusy)
            }
        }
        .sheet(isPresented: $newPort) { WorkspacePortEditor(model: model) }
        .sheet(item: $selectedPort) { WorkspacePortEditor(model: model, existing: $0) }
        .sheet(isPresented: $editDomain) { WorkspaceDomainEditor(model: model) }
        .sheet(isPresented: $editIdle) { WorkspaceIdleEditor(model: model) }
        .workspaceConfirmation($confirmation)
    }
    private func setAccess(_ enabled: Bool) async {
        await model.execute(.network(.init(publicAccess: enabled)), title: "Updating access…", refresh: [.publicAccess])
    }
}

private struct WorkspacePortEditor: View {
    let model: WorkspaceManagementModel
    var existing: ExposedPort?
    @State private var port = "3000"
    @State private var label = ""
    @State private var slug = ""

    var body: some View {
        WorkspaceControlEditor(title: existing == nil ? "Expose Port" : "Edit Public Link", model: model,
                               saveTitle: existing == nil ? "Expose" : "Save", canSave: valid, save: save) {
            Section {
                LabeledContent("Port") { TextField("3000", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing).disabled(existing != nil) }
                if existing == nil { TextField("Label (optional)", text: $label) }
                TextField(existing == nil ? "Slug (optional)" : "Slug", text: $slug).textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: { Text("The server should listen on 0.0.0.0. Slugs use 3–48 lowercase letters, numbers, or hyphens.") }
        }
        .onAppear { if let existing { port = String(existing.port); label = existing.label ?? ""; slug = existing.slug ?? "" } }
    }
    private var valid: Bool {
        (1...65535).contains(Int(port) ?? 0) && ((slug.isEmpty && existing == nil) || WorkspaceControlValidation.slug(slug))
    }
    private func save() async -> Bool {
        let command: WorkspaceManagementCommand = existing == nil
            ? .exposePort(port: Int(port) ?? 0, label: label.isEmpty ? nil : label, slug: slug.isEmpty ? nil : slug)
            : .updatePortSlug(port: Int(port) ?? 0, slug: slug)
        return await model.execute(command, title: "Updating public link…", refresh: [.publicAccess]) != nil
    }
}

private struct WorkspaceDomainEditor: View {
    let model: WorkspaceManagementModel
    @State private var host = ""
    @State private var port = "3000"
    @State private var includeWww = false
    @State private var check: WorkspaceDomainCheck?
    private var valid: Bool {
        !host.isEmpty && host.contains(".") && !host.contains(where: { $0.isWhitespace }) && !host.contains("/") && (1...65535).contains(Int(port) ?? 0)
    }

    var body: some View {
        WorkspaceControlEditor(title: "Custom Domain", model: model, saveTitle: "Connect", canSave: valid, save: {
            await model.execute(.connectDomain(domain: host, port: Int(port) ?? 0, includeWww: includeWww), title: "Connecting domain…", refresh: [.publicAccess]) != nil
        }) {
            Section {
                TextField("app.example.com", text: $host).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: host) { check = nil }
                LabeledContent("Port") { TextField("3000", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                Toggle("Include www", isOn: $includeWww)
                Button("Check DNS") {
                    Task { if case .domainCheck(let result) = await model.execute(.checkDomain(host), title: "Checking DNS…") { check = result } }
                }.disabled(!valid || model.isBusy)
            }
            if let check {
                Section("DNS") {
                    LabeledContent("Verification", value: check.verified == true ? "Verified" : "Not ready")
                    if let record = check.requiredRecords?.cname {
                        WorkspaceCopyRow(title: record.host ?? "CNAME", value: record.target ?? "edge.oblien.com")
                    }
                    if let record = check.requiredRecords?.txt {
                        WorkspaceCopyRow(title: record.host ?? "TXT", value: record.value ?? "")
                    }
                    ForEach(check.errors ?? [], id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear {
            if let domain = model.domain.value ?? nil { host = domain.customDomain ?? ""; port = String(domain.port ?? 3000); includeWww = domain.includeWww ?? false }
        }
    }
}

struct WorkspaceIdleEditor: View {
    let model: WorkspaceManagementModel
    @State private var enabled = false
    @State private var minutes = "15"
    @State private var expire = false
    @State private var hours = "24"
    private var supported: Bool { model.lifecycle.value?.snapshotSupported == true && model.lifecycle.value?.mode == "permanent" }
    var body: some View {
        WorkspaceControlEditor(title: "Sleep When Idle", model: model, canSave: !enabled || supported && (Int(minutes) ?? 0) >= 2 && (!expire || (Int(hours) ?? 0) >= 1), save: {
            await model.execute(.idle(suspendAfter: enabled ? (Int(minutes) ?? 15) * 60 : 0, stopAfter: expire ? (Int(hours) ?? 24) * 3600 : 0), title: "Saving sleep settings…", refresh: [.settings, .publicAccess]) != nil
        }) {
            Section {
                WorkspaceControlReadState(state: model.lifecycle)
                Toggle("Sleep When Idle", isOn: $enabled).disabled(!supported)
                if enabled {
                    LabeledContent("After (minutes)") { TextField("15", text: $minutes).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                }
            } footer: { Text(supported ? "Public links and custom domain requests wake the workspace with its programs intact." : model.lifecycle.value?.snapshotUnavailableReason ?? "Automatic sleep needs a persistent workspace with memory snapshot support.") }
            if enabled {
                Section {
                    Toggle("Expire Saved Memory", isOn: $expire)
                    if expire { LabeledContent("After (hours)") { TextField("24", text: $hours).keyboardType(.numberPad).multilineTextAlignment(.trailing) } }
                } footer: { Text("After saved memory expires, the next request boots from disk. Configure your app to start at boot.") }
            }
        }
        .task {
            await model.refresh(.settings)
            if let idle = model.lifecycle.value?.idle { enabled = idle.sleepSeconds > 0; minutes = String(max(2, idle.sleepSeconds / 60)); expire = idle.retentionSeconds > 0; hours = String(max(1, idle.retentionSeconds / 3600)) }
        }
    }
}
