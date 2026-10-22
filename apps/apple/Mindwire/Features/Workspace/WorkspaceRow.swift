import SwiftUI

/// Workspace identity and service state from the same cached sources as its detail page.
struct WorkspaceRow: View {
    let workspace: Workspace
    var catalog: [WorkspaceImage] = []
    @Environment(\.stores) private var stores

    var body: some View {
        EntityRow(style: .card) {
            Text(workspace.name)
        } subtitle: {
            Text(subtitle)
        } icon: {
            EntityCardIcon {
                if workspace.runtime.isLocal { AppIcon(.laptop, size: 28) }
                else if workspace.isCloud { AppIcon(.cloud, size: 28) }
                else { WorkspaceImageIcon(image: workspace.image, catalog: catalog, size: 28) }
            }
        } accessory: {
            WorkspaceDaemonStatusLabel(workspaceId: workspace.id, compact: true)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let count = stores.projects(forWorkspaceId: workspace.id).count
        let projects = count == 1 ? t("workspaces.oneProject") : t("workspaces.projectCount", ["count": "\(count)"])
        return [workspace.computerKind(in: stores), projects].joined(separator: " · ")
    }
}

extension Workspace {
    func computerKind(in stores: Stores) -> String {
        if runtime.isLocal { return "This Mac" }
        if isCloud { return t("assistant.setup.cloud") }
        if runtime.sandbox != nil { return t("newWorkspace.sandbox") }
        if let serverID = runtime.serverId, stores.connections.get(serverID)?.pairedComputer != nil { return "Computer" }
        return "SSH"
    }
}

/// Transparent native marks for common OS images; other images use the existing
/// catalog logo renderer without adding a network check for each workspace row.
struct WorkspaceImageIcon: View {
    let image: String?
    var catalog: [WorkspaceImage] = []
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let image, CloudImages.operatingSystem(image) == "macOS" {
                Image(systemName: "apple.logo")
                    .font(.system(size: size * 0.85))
                    .foregroundStyle(.primary)
            } else if let image, CloudImages.operatingSystem(image) == "Ubuntu" {
                Image("workspace-ubuntu")
                    .resizable().scaledToFit()
                    .foregroundStyle(Color(red: 0.91, green: 0.33, blue: 0.13))
            } else if let image, let entry = CloudImages.match(image, in: catalog) {
                RemoteLogoView(logo: entry.logo, brandHex: entry.color, label: entry.label, size: size)
            } else {
                AppIcon(image == nil ? .server : Icon.workspace, size: size)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
