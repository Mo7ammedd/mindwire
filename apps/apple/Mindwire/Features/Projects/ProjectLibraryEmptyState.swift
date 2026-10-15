import SwiftUI

/// The project library and its folders share one quiet, agent-led empty state.
struct ProjectLibraryEmptyState<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: Spacing.xxl) {
                HStack(spacing: Spacing.xl) {
                    ForEach([AgentID.codex, .claudeCode, .grok, .opencode]) { id in
                        AgentLogo(id: id, size: 36, color: .primary, mono: true)
                    }
                }
                .accessibilityHidden(true)
                Text(title).accessibilityAddTraits(.isHeader)
            }
        } description: {
            Text(message)
        } actions: {
            actions.controlSize(.large).tint(Palette.accent)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
