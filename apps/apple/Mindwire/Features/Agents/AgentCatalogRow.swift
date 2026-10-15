import SwiftUI

/// Shared identity for an available agent in setup and workspace suggestions.
struct AgentCatalogRow: View {
    let descriptor: AgentDescriptor

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.name).foregroundStyle(.primary)
                Text(descriptor.tagline)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        } icon: {
            AgentLogo(id: descriptor.id, size: 26)
                .accessibilityHidden(true)
        }
    }
}
