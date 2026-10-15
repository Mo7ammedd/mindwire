import SwiftUI

/// The same compact identity in the Agents tab and a workspace's agent list.
/// Harness artwork remains unboxed; status stays attached to its own agent.
struct AgentCompactLabel: View {
    let agent: Agent
    @ScaledMetric(relativeTo: .subheadline) private var logoSize: CGFloat = 26

    var body: some View {
        HStack(spacing: Spacing.sm) {
            AgentLogo(id: agent.agentType, size: logoSize)
                .accessibilityHidden(true)
            Text(agent.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            AgentRowStatus(agent: agent, includesWorkspaceStatus: false)
                .labelStyle(.iconOnly)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}
