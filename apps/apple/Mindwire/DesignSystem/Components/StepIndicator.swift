import SwiftUI

/// Discrete wizard progress — `total` capsule segments, filled through `current` (1-based).
/// Clearer than a continuous bar for "which step am I on / how many are left".
struct StepIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Capsule()
                    .fill(index < current ? Palette.accent : Color(.tertiarySystemFill))
                    .frame(height: 5)
            }
        }
    }
}
