import SwiftUI
import WebKit

struct ConnectionPortsScreen: View {
    let connection: Connection
    @Environment(\.stores) private var stores
    @State private var showAdd = false
    @State private var portText = "3000"
    @State private var preview: ConnectionPortForward?

    private var sessions: [ConnectionPortForward] {
        stores.portForwards.sessions.filter { $0.connection.id == connection.id }
    }
    private var port: Int? {
        guard let value = Int(portText), (1...65535).contains(value) else { return nil }
        return value
    }
    var body: some View {
        List {
            if sessions.isEmpty {
                Section {
                    WorkspaceControlEmptyState(title: "No forwarded ports", description: "Open a service running on this computer, such as a development server on port 3000.")
                    Button("Forward a Port", icon: Icon.plus) { showAdd = true }.tint(.primary)
                }
            } else {
                Section {
                    ForEach(sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Port \(session.remotePort)")
                                Text(session.error ?? session.url?.absoluteString ?? "Connecting…")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if session.connecting { ProgressView().controlSize(.small) }
                            AppMenu {
                                Button("Open Preview", icon: .globe) { preview = session }.disabled(session.url == nil)
                                if let url = session.url {
                                    Button("Copy Local Address", icon: .copy) { UIPasteboard.general.string = url.absoluteString }
                                }
                                if session.error != nil { Button("Retry", icon: .refresh) { session.start() } }
                                DestructiveButton("Close Forward", icon: .xCircle) { stores.portForwards.close(session) }
                            } label: { AppIcon(Icon.ellipsis).foregroundStyle(.primary) }
                        }
                    }
                } footer: {
                    Text("Private to this iPhone while Mindwire is active. These ports are not published to the internet.")
                }
            }
        }
        .navigationTitle("Port Forwarding").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !sessions.isEmpty {
                AppToolbarItem(placement: .topBarTrailing) {
                    Button("Forward a Port", icon: Icon.plus) { showAdd = true }.tint(.primary)
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Remote port", text: $portText).keyboardType(.numberPad)
                    } footer: {
                        Text("Connects to 127.0.0.1 on \(connection.name) through its encrypted SSH connection.")
                    }
                }
                .navigationTitle("Forward a Port").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAdd = false }.tint(.primary) }
                    AppToolbarItem(placement: .confirmationAction) {
                        Button("Forward") {
                            if let port { stores.portForwards.open(connection: connection, port: port); showAdd = false }
                        }.disabled(port == nil)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $preview) { session in
            NavigationStack {
                Group {
                    if let url = session.url { ForwardedWebPreview(url: url, connectionRevision: session.connectionRevision) }
                    else { ContentUnavailableView("Reconnecting", icon: .network, description: Text(session.error ?? "Waiting for the computer.")) }
                }
                .navigationTitle("Port \(session.remotePort)").navigationBarTitleDisplayMode(.inline)
                .toolbar { AppToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil }.tint(.primary) } }
            }
        }
    }
}

private struct ForwardedWebPreview: UIViewRepresentable {
    let url: URL
    let connectionRevision: Int
    final class Coordinator {
        var revision: Int?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: url))
        context.coordinator.revision = connectionRevision
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.revision != connectionRevision || web.url?.port != url.port {
            let current = web.url.flatMap { $0.host == url.host && $0.port == url.port ? $0 : nil } ?? url
            web.load(URLRequest(url: current))
            context.coordinator.revision = connectionRevision
        }
    }
}
