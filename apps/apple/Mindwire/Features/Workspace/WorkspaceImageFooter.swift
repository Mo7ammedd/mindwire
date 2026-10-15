import SwiftUI

/// The same image identity as the workspace row, with the full reference for details.
struct WorkspaceImageFooter: View {
    let image: String   // Docker ref, e.g. "oblien/claude-code:latest"
    @State private var catalog: [WorkspaceImage] = []
    @State private var loaded = false

    var body: some View {
        Section(t("workspace.image.title")) {
            HStack(spacing: Spacing.md) {
                WorkspaceImageIcon(image: image, catalog: catalog, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CloudImages.displayName(image, in: catalog)).foregroundStyle(.primary).lineLimit(1)
                    Text(image).font(.footnote).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.vertical, 2)
        }
        .task { await load() }
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        catalog = await CloudImages.cached()   // shared by the list, footer and image picker
    }
}
