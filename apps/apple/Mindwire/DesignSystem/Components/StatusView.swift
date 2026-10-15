import SwiftUI

/// Quiet, monochrome status — the calm replacement for the old colored status text.
/// Active states show a native mini spinner; only `.error` carries color (red). Everything
/// else is plain `.secondary`. Use this everywhere an agent status is shown.
struct AgentStatusLabel: View {
    let status: AgentStatus

    private var label: String { t("status.\(status.rawValue)") }

    var body: some View {
        switch status {
        case .provisioning:
            // Preparing the workspace / installing the agent — show activity.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(label).font(.subheadline).foregroundStyle(.secondary)
            }
        case .error:
            // Only error carries color — a quiet red label, not an indicator.
            Label(label, icon: .warning)
                .font(.subheadline)
                .foregroundStyle(.red)
                .labelStyle(.titleAndIcon)
        default:
            // running / provisioning / ready / idle / awaitingInput / archived — plain text.
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
