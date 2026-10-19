import SwiftUI

/// One publication flow for the catalog, app settings and native agent tool cards.
/// Hosting/account adapters stay in the client; Go only validates the saved app.
struct AppPublishSheet: View {
    let shortcut: AppShortcut
    @Environment(\.stores) private var stores
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var publicLink: URL?
    @State private var error: String?
    @State private var subscribing = false
    @State private var cloudReady = false

    private var current: AppShortcut { _ = stores.apps.revision; return stores.apps.get(shortcut.id) ?? shortcut }
    private var cloudID: String? { WorkspaceRepository.shared.get(current.workspaceId)?.runtime.workspaceId }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    AppShortcutIcon(shortcut: current, size: 66)
                    VStack(spacing: 8) {
                        Text(publicLink == nil ? "Publish \(current.name)" : "Your public link is ready")
                            .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        Text(description).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let link = publicLink ?? current.publicLink {
                        VStack(spacing: 12) {
                            Text(link.absoluteString).font(.subheadline).textSelection(.enabled).lineLimit(3)
                            Button { UIPasteboard.general.url = link } label: { Label("Copy Link", systemImage: "link").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).tint(.primary)
                        }.padding(18).background(AssistantStyle.surface, in: .rect(cornerRadius: 18))
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(Palette.danger).textSelection(.enabled) }
                    if cloudID != nil {
                        Button { Task { await publish() } } label: {
                            HStack(spacing: 10) {
                                if working { ProgressView().tint(BotColor.ink) }
                                Text(working ? "Publishing…" : (current.publicLink == nil && publicLink == nil ? "Publish app" : "Publish update"))
                                    .fontWeight(.semibold)
                            }.frame(maxWidth: .infinity).frame(minHeight: 38)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .tint(BotColor.brand.fill).foregroundStyle(BotColor.ink).disabled(working || current.archived)
                    } else if !cloudReady {
                        Button { subscribing = true } label: {
                            Label("Get Mindwire Cloud", systemImage: "cloud").fontWeight(.semibold)
                                .frame(maxWidth: .infinity).frame(minHeight: 38)
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .tint(BotColor.brand.fill).foregroundStyle(BotColor.ink)
                    }
                }.padding(28).frame(maxWidth: 480).frame(maxWidth: .infinity)
            }
            .background(AssistantStyle.canvas)
            .navigationTitle("Public sharing").navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(.primary).disabled(working) } }
        }
        .interactiveDismissDisabled(working)
        .sheet(isPresented: $subscribing) {
            NewWorkspaceScreen(assistantCloud: true) { _ in cloudReady = true; subscribing = false }
        }
        .frame(minWidth: ApplePlatform.isDesktop ? 460 : nil, minHeight: ApplePlatform.isDesktop ? 430 : nil)
    }

    private var description: String {
        if cloudReady { return "Cloud is ready. Ask App builder to move this app there and publish it." }
        if cloudID == nil { return "Public hosting needs Mindwire Cloud. Your app stays on this computer until you move it." }
        if !(current.staticDirectory ?? "").isEmpty { return "Share the finished website with anyone through an Oblien Page. Only the static build folder is published." }
        return "Anyone with the link can reach this app. Keep private information behind the app’s sign-in."
    }

    private func publish() async {
        guard !working, let cloudID else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let plan = try await stores.workspaceData.prepareAppPublication(current)
            let link = try await CloudAppPublishing.publish(plan, cloudID: cloudID, localApp: current, stores: stores)
            publicLink = link
            // A provider success survives a metadata conflict: refresh just this
            // record and retry its CAS without restarting the deployment.
            let http = try await stores.workspaceData.appAutomationHTTP(workspaceId: current.workspaceId)
            for attempt in 0..<3 {
                var latest: AppShortcut = try await http.decode("GET", "/apps/\(http.encQuery(current.id))")
                latest.workspaceId = current.workspaceId
                guard !latest.archived, latest.url == plan.app.url, latest.staticDirectory == plan.app.staticDirectory else {
                    throw BackendError.message("Published, but the app changed. Copy the link above before closing.")
                }
                do {
                    try await stores.workspaceData.editApp(latest, edit: .init(expectedRevision: latest.revision, publicUrl: link.absoluteString))
                    return
                } catch let failure as DaemonHTTPError where failure.status == 409 && attempt < 2 { continue }
            }
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private enum CloudAppPublishing {
    static func publish(_ plan: AppPublicationPlan, cloudID: String, localApp: AppShortcut, stores: Stores) async throws -> URL {
        let rawURL: String
        if plan.kind == "static", let directory = plan.directory {
            let body = try JSONSerialization.data(withJSONObject: ["appId": plan.app.id, "name": plan.app.name, "path": directory])
            guard let id = cloudID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !id.contains("/") else {
                throw BackendError.message("This cloud computer is invalid.")
            }
            guard let data = try await MindwireAPI.shared.accountRequest("POST", "/api/cloud/provider/workspace/\(id)/pages", body: body) else {
                throw BackendError.message("The page did not return a public link.")
            }
            struct Response: Decodable { struct Page: Decodable { let url: String }; let page: Page }
            rawURL = try JSONDecoder().decode(Response.self, from: data).page.url
        } else if plan.kind == "port", let port = plan.port {
            guard port != AppConstants.daemonPort else { throw BackendError.message("Mindwire’s service port can’t be published as an app.") }
            let ready = try await stores.workspaceData.openApp(localApp)
            guard ready.url == plan.app.url, ready.staticDirectory == plan.app.staticDirectory else {
                throw BackendError.message("The app changed while preparing. Try publishing again.")
            }
            let service = CloudWorkspaceService(workspaceId: cloudID)
            let existing = try await service.listPorts().first { $0.port == port }
            let exposed: ExposedPort
            if let existing { exposed = existing }
            else { exposed = try await service.exposePort(.init(port: port, label: plan.app.name)) }
            guard var link = URLComponents(string: exposed.url) else { throw BackendError.message("The computer did not return a public link.") }
            if let original = URLComponents(string: plan.app.url) { link.percentEncodedPath = original.percentEncodedPath }
            rawURL = link.string ?? ""
        } else { throw BackendError.message("This app’s publishing configuration is incomplete.") }
        guard let link = URL(string: rawURL), link.scheme == "https", link.host != nil, link.user == nil, link.password == nil else {
            throw BackendError.message("Publishing did not return a valid HTTPS link.")
        }
        return link
    }
}
