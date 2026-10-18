import SwiftUI
import UIKit

/// Desktop presentation uses the same conversation and bot stores as the phone.
enum AssistantDesktopStyle {
    static let canvas = adaptive(light: 0xFAFAF8, dark: 0x242423)
    static let sidebar = adaptive(light: 0xF1F1EF, dark: 0x151514)
    static let surface = adaptive(light: 0xEAEAE7, dark: 0x30302F)
    static let selection = adaptive(light: 0xE3E3DF, dark: 0x292928)
    static let outgoing = Color(red: 0.93, green: 0.93, blue: 0.91)
    static let separator = Color.primary.opacity(0.09)
    static let sidebarInset: CGFloat = 16
    static let botRailWidth: CGFloat = 72
    static let headerHeight: CGFloat = 52
    static let conversationWidth: CGFloat = 920
    static let gutter: CGFloat = 24
    static let messageRadius: CGFloat = 20
    static let rowRadius: CGFloat = 18

    static func sidebarWidth(in windowWidth: CGFloat) -> CGFloat {
        min(340, max(260, windowWidth * 0.28))
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

/// Quiet pointer feedback on desktop controls, without introducing another
/// bordered button inside the window's rounded surfaces.
struct AssistantDesktopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DesktopButton(configuration: configuration)
    }

    private struct DesktopButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(configuration.isPressed ? AssistantDesktopStyle.selection
                            : hovered ? AssistantDesktopStyle.surface : .clear,
                            in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(.rect(cornerRadius: 12, style: .continuous))
                .onHover { hovered = $0 }
        }
    }
}

/// Compact desktop actions share pointer, disabled, and keyboard behavior with SwiftUI Buttons.
struct DesktopActionButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Action(configuration: configuration, prominent: prominent)
    }

    private struct Action: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 28)
                .foregroundStyle(prominent ? Palette.onAccent : Color.primary)
                .background(prominent ? Palette.accent : AssistantDesktopStyle.surface,
                            in: .rect(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : hovered && isEnabled ? 0.04 : 0))
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.rect(cornerRadius: 7))
                .onHover { hovered = $0 }
        }
    }
}

struct AssistantDesktopWindow: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.background { DesktopWindowConfiguration().frame(width: 0, height: 0) }
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Only configures this scene. It never activates, replaces or resizes another app window.
private struct DesktopWindowConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowObserver { WindowObserver() }
    func updateUIView(_ view: WindowObserver, context: Context) {}

    final class WindowObserver: UIView {
        private weak var configuredScene: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene, scene !== configuredScene else { return }
            configuredScene = scene
            scene.sizeRestrictions?.minimumSize = CGSize(width: 880, height: 620)
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
            scene.titlebar?.separatorStyle = .none
            scene.titlebar?.toolbarStyle = .unifiedCompact

            // Respect subsequent user resizing and restored windows. Request a comfortable
            // starting frame only on the first use of the desktop bot layout.
            let key = "mindwire.desktop.windowLayout"
            guard UserDefaults.standard.integer(forKey: key) < 1 else { return }
            UserDefaults.standard.set(1, forKey: key)
            let screen = scene.screen.bounds
            let size = CGSize(width: min(1280, screen.width - 80), height: min(820, screen.height - 80))
            guard scene.coordinateSpace.bounds.width < size.width else { return }
            let frame = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                               width: size.width, height: size.height)
            scene.requestGeometryUpdate(.Mac(systemFrame: frame)) { error in
                APILog.note("desktop: preferred window size unavailable — \(error.localizedDescription)")
            }
        }
    }
}
#endif
