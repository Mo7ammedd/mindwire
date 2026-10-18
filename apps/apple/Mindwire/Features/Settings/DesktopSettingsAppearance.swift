#if targetEnvironment(macCatalyst)
import SwiftUI

/// Desktop presentation of the shared appearance preferences.
struct DesktopAppearanceControls: View {
    @Binding var appearance: String
    @Binding var textSize: String

    var body: some View {
        DesktopSettingsPage {
            VStack(alignment: .leading, spacing: 12) {
                Text("Theme").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 14) {
                    themeChoice("System", value: "system")
                    themeChoice("Light", value: "light")
                    themeChoice("Dark", value: "dark")
                }
            }

            DesktopSettingsGroup {
                HStack {
                    Text(t("settings.textSize.title"))
                    Spacer(minLength: 16)
                    Picker(t("settings.textSize.title"), selection: $textSize) {
                        ForEach(ChatTextSize.allCases) { size in Text(size.label).tag(size.rawValue) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.regular)
                    .frame(width: 216)
                    .accessibilityIdentifier("settings.chatTextSize")
                }
                .padding(16)

                Divider().padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Preview").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 10) {
                        AssistantBotAvatar(botId: "settings-preview", icon: "peach-pebble", size: 26)
                        MessageContentView(text: "A little help, every day.")
                            .modifier(ChatAssistantBubble())
                    }
                    .environment(\.desktopMessenger, true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AssistantDesktopStyle.canvas.opacity(0.65))
            }

            DesktopSettingsGroup {
                NavigationLink { AssistantBotAppearanceSettings() } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: -6) {
                            AssistantBotAvatar(botId: "icons-peach", icon: "peach-squircle", size: 28)
                            AssistantBotAvatar(botId: "icons-lilac", icon: "lilac-sprout", size: 28)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t("assistant.icons.title"))
                            Text("Colors and characters").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.botIcons")
            }
        }
    }

    private func themeChoice(_ title: String, value: String) -> some View {
        let selected = appearance == value
        return Button { appearance = value } label: {
            VStack(spacing: 9) {
                DesktopThemePreview(appearance: value)
                    .frame(height: 78)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected ? Palette.accent : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                    }
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Palette.accent : Color.secondary.opacity(0.55))
                    Text(title).foregroundStyle(.primary)
                }
                .font(.system(size: 12, weight: selected ? .medium : .regular))
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.theme.\(value)")
    }
}

private struct DesktopThemePreview: View {
    let appearance: String

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                miniature.environment(\.colorScheme, appearance == "dark" ? .dark : .light)
                if appearance == "system" {
                    miniature.environment(\.colorScheme, .dark)
                        .mask(alignment: .trailing) { Rectangle().frame(width: geometry.size.width / 2) }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var miniature: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 2) {
                    ForEach(0..<3) { _ in Circle().fill(Color.secondary.opacity(0.4)).frame(width: 3, height: 3) }
                }
                RoundedRectangle(cornerRadius: 2).fill(Palette.accent.opacity(0.25)).frame(height: 6)
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.18)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.18)).frame(height: 4)
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(width: 34)
            .background(AssistantDesktopStyle.sidebar)

            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(Color.primary.opacity(0.7)).frame(width: 27, height: 3)
                Capsule().fill(AssistantDesktopStyle.outgoing).frame(width: 33, height: 9)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                RoundedRectangle(cornerRadius: 4).fill(AssistantDesktopStyle.surface).frame(height: 16)
                Spacer(minLength: 0)
                Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1).frame(height: 9)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AssistantDesktopStyle.canvas)
        }
    }
}

/// A single inset and content width keep every desktop preference pane aligned.
struct DesktopSettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22, content: content)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct DesktopSettingsGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AssistantDesktopStyle.surface.opacity(0.55))
            .clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
    }
}
#endif
