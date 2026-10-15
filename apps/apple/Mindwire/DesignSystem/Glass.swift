import SwiftUI

/// Liquid Glass chrome helper.
///
/// Rule of thumb (iOS 26): **glass is chrome only** — toolbars, floating panels, FABs,
/// interactive controls. Content (list rows, cards) uses native grouped surfaces. Never
/// nest glass on glass; group adjacent glass in a `GlassEffectContainer`.
extension View {
    /// Floating glass chrome behind the given shape (defaults to a capsule).
    func chromeGlass<S: Shape>(_ shape: S = Capsule(), tint: Color? = nil, interactive: Bool = false) -> some View {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return self.glassEffect(glass, in: shape)
    }
}
