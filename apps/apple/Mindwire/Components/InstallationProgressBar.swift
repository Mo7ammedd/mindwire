import SwiftUI

/// iOS renders an indeterminate linear ProgressView as an empty track. Show a moving segment
/// for step-based installation, and use the native percentage bar for measured downloads.
struct InstallationProgressBar: View {
    var progress: Double? = nil
    var color: Color = Palette.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(color)
            } else {
                GeometryReader { geometry in
                    Capsule().fill(Color.secondary.opacity(0.2))
                        .overlay(alignment: .leading) {
                            Capsule().fill(color)
                                .frame(width: geometry.size.width * 0.3)
                                .phaseAnimator(reduceMotion ? [0.5] : [0.0, 1.0]) { segment, phase in
                                    segment.offset(x: geometry.size.width * 0.7 * phase)
                                } animation: { _ in
                                    .easeInOut(duration: 1.2)
                                }
                        }
                }
                .frame(height: 4)
            }
        }
        .accessibilityLabel(t("agentUpdates.installProgress"))
    }
}
