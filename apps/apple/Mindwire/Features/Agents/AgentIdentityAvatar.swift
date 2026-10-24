import SwiftUI

/// Reuses saved bot artwork and native harness marks across the grid and sidebar.
struct AgentIdentityAvatar: View {
    let identity: AgentListIdentity
    var size: CGFloat
    var isWorking = false
    @Environment(\.chatAccent) private var accent

    var body: some View {
        switch identity {
        case .bot(let bot):
            AssistantBotAvatar(botId: bot.id, icon: bot.icon, size: size, isWorking: isWorking)
        case .plain(let agent):
            AgentLogo(id: agent.agentType, size: size * 0.78)
                .frame(width: size, height: size)
                .overlay {
                    if isWorking { ActivityRing(size: size + 4, isAnimating: true, color: accent) }
                }
                .accessibilityHidden(true)
        }
    }
}
