import SwiftUI

/// Creation, project agents, details and settings all render the same service-owned readiness.
/// Only the observer belongs to this view; dismissing it never cancels the installation job.
struct AgentReadinessView<Content: View>: View {
    let agent: Agent
    let session: DaemonSession?
    var requiresAuthentication = true
    var preferredAuthMethodID: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.scenePhase) private var scenePhase

    private struct ObservationKey: Hashable {
        let agentId: String?
        let active: Bool
    }

    var body: some View {
        AgentAuthPresenter(model: session, preferredMethodID: preferredAuthMethodID) {
            switch session?.phase ?? .checking {
            case .ready:
                content()
            case .needsAuth:
                if requiresAuthentication, let session {
                    AgentConnectGate(agent: agent, model: session)
                } else {
                    content()
                }
            case .checking:
                DaemonPreparingView(agent: agent, activity: session?.activity ?? .checking,
                    message: session?.statusMessage, steps: session?.prepSteps ?? [],
                    progress: session?.preparationProgress, plan: session?.preparationPlan ?? [],
                    currentStep: session?.preparationCurrentStep, startedAt: session?.preparationStartedAt)
            case .unreachable(let message):
                ContentUnavailableView {
                    Label(t("agentAuth.unreachable.title"), icon: .wifiOff)
                } description: {
                    Text(message)
                } actions: {
                    Button(t("common.retry")) { Task { await session?.load(force: true) } }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.accent)
                }
            }
        }
        .task(id: ObservationKey(agentId: session?.agentId, active: scenePhase == .active)) {
            guard scenePhase == .active, let session else { return }
            await session.load()
            await session.observePreparation()
        }
    }
}
