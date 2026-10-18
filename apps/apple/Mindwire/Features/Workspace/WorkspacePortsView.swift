import SwiftUI

/// Exposed ports for a cloud workspace: tap a row to open the public URL, swipe to unexpose, or
/// expose a new port (gated on Oblien sign-in). Self-hosted runtimes don't expose ports.
struct WorkspacePortsView: View {
    let model: WorkspaceModel
    @State private var showExpose = false
    @State private var portText = ""
    @State private var showLogin = false
    @State private var pendingPort: Int?

    var body: some View {
        Section(t("workspace.ports.title")) {
            if model.ports.isEmpty {
                Text(t("workspace.ports.empty")).foregroundStyle(.secondary)
            } else {
                ForEach(model.ports) { port in row(port) }
            }
            Button {
                portText = ""
                showExpose = true
            } label: {
                Label(t("workspace.ports.expose"), icon: Icon.plus)
            }
            .tint(.primary)
        }
        .inputDialog(
            titleKey: "workspace.ports.expose",
            isPresented: $showExpose,
            text: $portText,
            placeholder: "3000",
            confirmKey: "workspace.ports.expose"
        ) {
            submitExpose()
        }
        .mindwireLoginSheet(isPresented: $showLogin) {
            if let port = pendingPort { pendingPort = nil; Task { await model.exposePort(port) } }
        }
    }

    @ViewBuilder
    private func row(_ port: ExposedPort) -> some View {
        if let url = URL(string: port.url), !port.url.isEmpty {
            Link(destination: url) {
                LabeledContent(":\(port.port)") { Text(port.url).lineLimit(1) }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    Task { await model.unexposePort(port.port) }
                } label: { Label(t("common.delete"), icon: Icon.trash) }
            }
        } else {
            LabeledContent(":\(port.port)", value: "")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await model.unexposePort(port.port) }
                    } label: { Label(t("common.delete"), icon: Icon.trash) }
                }
        }
    }

    private func submitExpose() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)),
              port >= 1, port <= 65535 else { return }
        // Exposing a port is an Oblien-cloud, user-scoped feature — gate it on sign-in (self-host
        // runtimes don't go through Oblien, so they expose without a prompt).
        guard model.runtime.isCloud else {
            Task { await model.exposePort(port) }
            return
        }
        Task {
            if await MindwireAuth.shared.ensure() {
                await model.exposePort(port)
            } else {
                pendingPort = port
                showLogin = true
            }
        }
    }
}
