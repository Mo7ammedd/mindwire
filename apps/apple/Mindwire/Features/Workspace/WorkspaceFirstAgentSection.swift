import SwiftUI

/// One entry point for a fresh workspace. Agent selection lives in New Agent;
/// the catalog logos here are a compact preview of the available harnesses.
struct WorkspaceFirstAgentSection: View {
    @State private var model: NewAgentModel
    let onAdd: () -> Void

    init(workspaceId: String, releaseCatalog: ReleaseCatalog = .shared, onAdd: @escaping () -> Void) {
        _model = State(initialValue: NewAgentModel(workspaceId: workspaceId, releaseCatalog: releaseCatalog))
        self.onAdd = onAdd
    }

    private var icons: [AgentID] {
        model.catalog.isEmpty ? [.claudeCode, .codex, .grok, .opencode] : model.catalog.map(\.id)
    }

    var body: some View {
        Section {
            Button(action: onAdd) {
                HStack(spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(t("workspace.agents.first.title"))
                            .font(.headline).foregroundStyle(.primary)
                        Text(t("workspace.agents.first.body"))
                            .font(.subheadline).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 28), spacing: Spacing.md)],
                                  alignment: .leading, spacing: Spacing.sm) {
                            ForEach(icons) { AgentLogo(id: $0, size: 26) }
                        }
                        .padding(.top, Spacing.xs)
                        .accessibilityHidden(true)
                    }
                    AppIcon(Icon.chevron)
                        .font(.footnote).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .tint(.primary)
            .accessibilityLabel(t("workspace.agents.first.title"))
            .accessibilityHint(t("workspace.agents.first.body"))
        }
        .task { await model.loadCatalog() }
    }
}
