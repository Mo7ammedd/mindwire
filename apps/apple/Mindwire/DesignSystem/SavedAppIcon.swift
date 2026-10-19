import SwiftUI

/// Shared app artwork for shortcuts, chat cards and notification avatars.
struct SavedAppIcon: View {
    let id: String
    var icon: String?
    var size: CGFloat = 48

    var body: some View {
        if let icon, let prefix = icon.split(separator: "-").first, BotColor(rawValue: String(prefix)) != nil {
            AssistantBotAvatar(botId: id, icon: icon, size: size)
        } else {
            let color = BotColor.allCases[Int(AssistantBotIcon.seed(id) % UInt64(BotColor.allCases.count))]
            let symbol = icon.flatMap { UIImage(systemName: $0) != nil ? $0 : nil } ?? "app.fill"
            Image(systemName: symbol).font(.system(size: size * 0.43, weight: .medium)).foregroundStyle(BotColor.ink)
                .frame(width: size, height: size).background(color.fill, in: .rect(cornerRadius: size * 0.26))
        }
    }
}
