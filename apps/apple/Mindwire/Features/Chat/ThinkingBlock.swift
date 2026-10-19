import SwiftUI

/// A quiet reasoning disclosure. Native activity is driven by the active part; completed
/// reasoning has no pulse or decorative badge. Withheld text still shows the harness's token count.
struct ThinkingBlock: View {
    let text: String
    var durationMs: Int? = nil
    var tokens: Int? = nil
    var isLive = false
    private var tokenLabel: String? {
        guard let tokens, tokens > 0 else { return nil }
        return t("chat.thinking.tokens", ["n": Self.formatTokens(tokens)])
    }

    /// 126 → "126", 1234 → "1.2k" (compact, like the editor's preview).
    static func formatTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    var body: some View {
        ChatDetailDisclosure(text: text, metadata: tokenLabel) {
            HStack(spacing: Spacing.sm) {
                ChatToolIcon(symbol: .brain)
                Text(t(isLive ? "chat.thinking.live" : "chat.thinking.doneNoTime"))
                if !isLive, let ms = durationMs, ms >= 500 {
                    Text("\(max(1, ms / 1000))s").font(.caption).monospacedDigit()
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let tokenLabel {
                    Text(tokenLabel).font(.caption).monospacedDigit()
                }
                if isLive { ProgressView().chatActivityTint().controlSize(.mini) }
            }
        }
    }
}
