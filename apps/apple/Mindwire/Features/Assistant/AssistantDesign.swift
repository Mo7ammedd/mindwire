import SwiftUI

/// Presentation only. General setup shares these surfaces; chat and Developer screens keep
/// their existing components. No connection, draft or conversation state lives here.
enum AssistantStyle {
    static let canvas = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
}

/// The bundled mark has generous artwork padding. Fit the actual mark to its requested size.
struct AssistantBrandMark: View {
    var size: CGFloat
    var color: Color = .primary

    var body: some View {
        OblienMark(size: size * 1.75, color: color)
            .frame(width: size, height: size)
            .clipped()
            .accessibilityHidden(true)
    }
}

struct AssistantPage<Content: View, Footer: View>: View {
    var reservesFooter = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28, content: content)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 28)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background {
            AssistantStyle.canvas.ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if reservesFooter {
                VStack(spacing: 12, content: footer)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                    .background(AssistantStyle.canvas)
            }
        }
    }
}

extension AssistantPage where Footer == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        reservesFooter = false
        self.content = content
        footer = { EmptyView() }
    }
}

struct AssistantHeading: View {
    var eyebrow: String = ""
    let title: String
    var detail: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !eyebrow.isEmpty {
                Text(eyebrow).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(title).font(.largeTitle.weight(.semibold)).tracking(-0.7).fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AssistantOption: View {
    let title: String
    let detail: String
    let icon: AppIconName
    var selected: Bool? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                AppIcon(icon, size: 25, decorative: true)
                    .frame(width: 48, height: 48)
                    .background(AssistantStyle.canvas, in: .rect(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AppIcon(selected == true ? .checkCircleFilled : selected == false ? .circle : .chevronRight,
                        size: 20, decorative: true)
                    .foregroundStyle(selected == true ? Palette.accent : Color.secondary)
            }
            .padding(18)
            .background(selected == true ? Palette.accent.opacity(0.07) : AssistantStyle.surface,
                        in: .rect(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(selected == true ? Palette.accent.opacity(0.7) : .clear, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(AssistantPressStyle()).foregroundStyle(.primary)
        .accessibilityAddTraits(selected == true ? .isSelected : [])
    }
}

struct AssistantPrimaryButton: View {
    let title: String
    var icon: AppIconName = .arrowUpRight
    var busy = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(.headline)
                Spacer(minLength: 12)
                if busy { ProgressView().tint(AssistantStyle.canvas) }
                else { AppIcon(icon, size: 22, decorative: true) }
            }
            .padding(.horizontal, 22).padding(.vertical, 19)
            .frame(maxWidth: .infinity)
            .foregroundStyle(AssistantStyle.canvas)
            .background(Color.primary.opacity(isEnabled ? 1 : 0.25), in: .capsule)
        }
        .buttonStyle(AssistantPressStyle()).disabled(busy)
    }
}

/// Static bundled artwork: no perpetual animation, network assets or imitation QR code.
struct AssistantArtwork: View {
    var computer = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Circle().fill(Palette.accent.opacity(0.06)).frame(width: 150, height: 150)
            Circle().strokeBorder(Palette.accent.opacity(0.12), lineWidth: 1).frame(width: 126, height: 126)
            RoundedRectangle(cornerRadius: 30)
                .fill(AssistantStyle.canvas).frame(width: 88, height: 88)
                .rotationEffect(.degrees(-9))
                .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.06), radius: 20, y: 10)
            if computer { AppIcon(.laptop, size: 46).foregroundStyle(Palette.accent) }
            else { AppLogo(size: 44) }
            tile(computer ? .scan : .fileText).offset(x: -85, y: 22).rotationEffect(.degrees(-8))
            tile(computer ? .link : .sparkles).offset(x: 84, y: -22).rotationEffect(.degrees(9))
        }
        .frame(maxWidth: .infinity).frame(height: 160)
        .accessibilityHidden(true)
    }

    private func tile(_ icon: AppIconName) -> some View {
        AppIcon(icon, size: 25).foregroundStyle(.secondary)
            .frame(width: 46, height: 46)
            .background(AssistantStyle.canvas, in: .rect(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.05)) }
    }
}

struct AssistantSetupProgress: View {
    let step: Int
    private let labels = ["assistant.progress.computer", "assistant.progress.account", "assistant.progress.ready"]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3) { index in
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(index <= step ? Color.primary : Color.primary.opacity(0.08)).frame(height: 3)
                    Text(t(labels[index])).font(.caption.weight(index == step ? .semibold : .regular))
                        .foregroundStyle(index == step ? Color.primary : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("assistant.step", ["step": String(step + 1)]) + ": " + t(labels[step]))
    }
}

struct AssistantPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.76 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Push existing setup screens into General's single stack or present them on their own.
struct SetupNavigation<Content: View>: View {
    var embedded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if embedded { content() }
        else { NavigationStack { content() } }
    }
}
