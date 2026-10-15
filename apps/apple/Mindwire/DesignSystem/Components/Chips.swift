import SwiftUI

/// Initials avatar in the brand accent — used for the account row. (The rest of the old
/// chip zoo — IconTile/Pill/StatusDot/SectionLabel — was retired for native rows.)
struct Avatar: View {
    let initial: String
    var size: CGFloat = 40

    var body: some View {
        Text(initial.prefix(1).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Palette.onAccent)
            .frame(width: size, height: size)
            .background(Palette.accent, in: Circle())
    }
}
