import SwiftUI

private enum WorkspaceNetworkEditorKind: String, Identifiable {
    case internet = "Internet Access", inbound = "Inbound Ports", proxy = "Outbound Proxy", address = "Outbound IP", privateLinks = "Private Network"
    var id: String { rawValue }
}

struct WorkspaceNetworkScreen: View {
    let model: WorkspaceManagementModel
    let workspaceId: String
    let repository: WorkspaceRepository
    @State private var editing: WorkspaceNetworkEditorKind?

    var body: some View {
        WorkspaceControlPage(title: "Network", model: model, feature: .network) {
            Section("IP Addresses") {
                WorkspaceControlReadState(state: model.network)
                if let network = model.network.value {
                    if let ip = network.ip { WorkspaceCopyRow(title: "Private IP", value: ip) }
                    Button { editing = .address } label: {
                        LabeledContent("Outbound IP", value: network.outboundIp ?? "Automatic")
                    }.tint(.primary)
                }
            }
            if let network = model.network.value {
                Section("Traffic Rules") {
                    editRow(.internet, value: network.allowInternet == false ? "Disabled" : network.egress?.contains("*") == true ? "Unrestricted" : "Restricted")
                    editRow(.inbound, value: (network.ingressPorts ?? []).isEmpty ? "All ports" : "\(network.ingressPorts?.count ?? 0) ports")
                    editRow(.privateLinks, value: "\(network.privateLinks?.count ?? 0) workspaces")
                    editRow(.proxy, value: network.outboundMode == "custom" ? "Custom" : "Managed")
                }
            }
        }
        .sheet(item: $editing) { kind in
            WorkspaceNetworkEditor(model: model, workspaceId: workspaceId, repository: repository, kind: kind)
        }
    }
    private func editRow(_ kind: WorkspaceNetworkEditorKind, value: String) -> some View {
        Button { editing = kind } label: {
            HStack {
                LabeledContent(kind.rawValue, value: value)
                AppIcon(Icon.chevron).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }.tint(.primary).disabled(model.isBusy)
    }
}

private struct WorkspaceNetworkEditor: View {
    let model: WorkspaceManagementModel
    let workspaceId: String
    let repository: WorkspaceRepository
    let kind: WorkspaceNetworkEditorKind
    @State private var internetMode = "unrestricted"
    @State private var hosts = ""
    @State private var allPorts = true
    @State private var portText = ""
    @State private var links = Set<String>()
    @State private var outboundIP = ""
    @State private var proxyMode = "managed"
    @State private var proxyHost = ""
    @State private var proxyPort = "8080"
    @State private var proxyProtocol = "http"
    @State private var proxyAuth = false
    @State private var username = ""
    @State private var password = ""
    @State private var initialized = false
    private var valid: Bool {
        switch kind {
        case .inbound: return allPorts || ((try? WorkspaceControlValidation.ports(portText))?.isEmpty == false)
        case .internet: return internetMode != "restricted" || !hostList.isEmpty
        case .address: return !outboundIP.isEmpty
        case .proxy: return proxyMode == "managed" || (!proxyHost.isEmpty && (1...65535).contains(Int(proxyPort) ?? 0) && (!proxyAuth || (!username.isEmpty && !password.isEmpty)))
        case .privateLinks: return true
        }
    }
    private var hostList: [String] { hosts.split { $0 == "," || $0.isWhitespace }.map(String.init) }

    var body: some View {
        WorkspaceControlEditor(title: kind.rawValue, model: model, canSave: initialized && valid, save: save) {
            switch kind {
            case .internet:
                Section {
                    Picker("Internet", selection: $internetMode) {
                        Text("Unrestricted").tag("unrestricted"); Text("Allowed hosts only").tag("restricted"); Text("Disabled").tag("disabled")
                    }.pickerStyle(.inline)
                }
                if internetMode == "restricted" {
                    Section {
                        TextField("api.example.com", text: $hosts, axis: .vertical).lineLimit(4...8)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Allowed Hosts & CIDRs") } footer: { Text("One hostname, IP address, or CIDR per line. Up to 50 entries.") }
                }
                if internetMode == "disabled" { Section { Text("Agents cannot reach model APIs or download packages while internet access is disabled.").font(.footnote).foregroundStyle(.secondary) } }
            case .inbound:
                Section {
                    Toggle("Allow All Ports", isOn: $allPorts)
                    if !allPorts { TextField("3000, 8080", text: $portText, axis: .vertical).keyboardType(.numbersAndPunctuation) }
                } footer: { Text("These rules control incoming connections. Public preview URLs are managed in Public Access.") }
            case .privateLinks:
                Section {
                    ForEach(repository.all.filter { $0.isCloud && $0.id != workspaceId }) { workspace in
                        Toggle(isOn: Binding(get: { links.contains(workspace.id) }, set: { selected in
                            if selected { links.insert(workspace.id) } else { links.remove(workspace.id) }
                        })) {
                            EntityRow { Text(workspace.name) }
                                subtitle: { Text(workspace.image ?? "Oblien") }
                                icon: { WorkspaceImageIcon(image: workspace.image, size: 22) }
                        }
                    }
                    if repository.all.filter({ $0.isCloud && $0.id != workspaceId }).isEmpty {
                        WorkspaceControlEmptyState(title: "No other workspaces", description: "Create another Oblien workspace to connect it privately.")
                    }
                } footer: { Text("Selected workspaces can call this workspace over the private network. This does not expose it to the internet.") }
            case .address:
                Section {
                    WorkspaceControlReadState(state: model.outboundIPs)
                    Picker("Outbound IP", selection: $outboundIP) {
                        ForEach(model.outboundIPs.value ?? []) { address in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(address.ip)
                                if let code = address.countryCode { Text(Locale.current.localizedString(forRegionCode: code) ?? code).font(.subheadline).foregroundStyle(.secondary) }
                            }.tag(address.ip)
                        }
                    }.pickerStyle(.inline)
                }
            case .proxy:
                Section {
                    Picker("Routing", selection: $proxyMode) { Text("Managed by Oblien").tag("managed"); Text("Custom proxy").tag("custom") }
                }
                if proxyMode == "custom" {
                    Section {
                        TextField("Public IPv4 address", text: $proxyHost).keyboardType(.decimalPad)
                        LabeledContent("Port") { TextField("8080", text: $proxyPort).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                        Picker("Protocol", selection: $proxyProtocol) { Text("HTTP").tag("http"); Text("HTTPS").tag("https") }
                        Toggle("Authentication", isOn: $proxyAuth)
                        if proxyAuth {
                            TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("Password", text: $password)
                        }
                    } header: { Text("Proxy") } footer: { Text("Use a public IPv4 address. Oblien checks the proxy before applying it. Existing passwords are never returned; enter them again when replacing proxy settings.") }
                }
            }
        }
        .task {
            guard !initialized else { return }
            let network = model.network.value
            internetMode = network?.allowInternet == false ? "disabled" : network?.egress?.contains("*") == true ? "unrestricted" : "restricted"
            hosts = (network?.egress ?? []).filter { $0 != "*" }.joined(separator: "\n")
            allPorts = (network?.ingressPorts ?? []).isEmpty
            portText = (network?.ingressPorts ?? []).map(String.init).joined(separator: ", ")
            links = Set(network?.privateLinks?.map(\.resolvedId).filter { !$0.isEmpty } ?? [])
            outboundIP = network?.outboundIp ?? ""
            proxyMode = network?.outboundMode ?? "managed"; proxyHost = network?.outboundProxy?.host ?? ""
            proxyPort = String(network?.outboundProxy?.port ?? 8080); proxyProtocol = network?.outboundProxy?.protocol ?? "http"
            proxyAuth = network?.outboundProxy?.hasCredentials ?? false
            initialized = true
            if kind == .address { await model.loadOutboundIPs() }
        }
    }

    private func save() async -> Bool {
        do {
            let command: WorkspaceManagementCommand
            switch kind {
            case .internet:
                guard hostList.count <= 50 else { throw WorkspaceControlError(message: "Use at most 50 hosts or CIDRs.") }
                command = .network(.init(allowInternet: internetMode != "disabled", egress: internetMode == "unrestricted" ? ["*"] : internetMode == "disabled" ? [] : hostList))
            case .inbound: command = .network(.init(ingressPorts: allPorts ? [] : try WorkspaceControlValidation.ports(portText)))
            case .privateLinks: command = .network(.init(privateLinkIds: links.sorted()))
            case .address: command = .outboundIP(outboundIP)
            case .proxy:
                command = .network(.init(outboundMode: proxyMode, customProxy: proxyMode == "custom" ? .init(host: proxyHost, port: Int(proxyPort) ?? 0, protocol: proxyProtocol, username: proxyAuth ? username : nil, password: proxyAuth ? password : nil) : nil))
            }
            return await model.execute(command, title: "Updating network…", refresh: [.network]) != nil
        } catch { model.actionError = WorkspaceControlError.describe(error); return false }
    }
}
