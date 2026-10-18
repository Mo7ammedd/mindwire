import SwiftUI

/// The same character controls are used before creation and when editing a saved bot.
struct BotAppearanceEditor: View {
    let botId: String
    @Binding var selection: AssistantBotIcon
    var onChange: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("assistant.icons.color")).font(.subheadline.weight(.medium))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: ApplePlatform.isDesktop ? 10 : 5), spacing: 6) {
                        ForEach(BotColor.allCases) { color in
                            Button {
                                selection.color = color
                                onChange()
                            } label: {
                                Circle().fill(color.fill).frame(width: 30, height: 30)
                                    .overlay {
                                        if selection.color == color {
                                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                                                .foregroundStyle(BotColor.ink)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: ApplePlatform.isDesktop ? 34 : 44)
                            }
                            .accessibilityLabel(color.title)
                            .accessibilityAddTraits(selection.color == color ? .isSelected : [])
                            .accessibilityIdentifier("assistant.icon.color.\(color.rawValue)")
                        }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(t("assistant.icons.character")).font(.subheadline.weight(.medium))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: ApplePlatform.isDesktop ? 48 : 58), spacing: 8)], spacing: 8) {
                    ForEach(BotCharacter.allCases) { character in
                        let icon = AssistantBotIcon(color: selection.color, character: character)
                        Button {
                            selection.character = character
                            onChange()
                        } label: {
                            AssistantBotAvatar(botId: botId, icon: icon.id, size: ApplePlatform.isDesktop ? 36 : 40)
                                .frame(maxWidth: .infinity, minHeight: ApplePlatform.isDesktop ? 56 : 66)
                                .background(AssistantStyle.surface, in: .rect(cornerRadius: 18))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18)
                                        .strokeBorder(selection.character == character ? Palette.accent : .clear, lineWidth: 2)
                                }
                        }
                        .accessibilityLabel(character.title)
                        .accessibilityAddTraits(selection.character == character ? .isSelected : [])
                        .accessibilityIdentifier("assistant.icon.character.\(character.rawValue)")
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
