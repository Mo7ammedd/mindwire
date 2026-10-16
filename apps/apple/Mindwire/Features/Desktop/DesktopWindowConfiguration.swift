#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Gives the chat room to breathe on first opening, then leaves window placement to macOS.
struct DesktopWindowConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowView { WindowView() }
    func updateUIView(_ uiView: WindowView, context: Context) { uiView.configure() }

    final class WindowView: UIView {
        // A one-time migration also enlarges windows saved by the earlier compact Mac layout.
        private static let initialSizeKey = "mindwire.desktop.window.chat-layout-v2"
        private weak var observedScene: UIWindowScene?
        private var requestedInitialSize = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            configure()
        }

        func configure() {
            backgroundColor = .clear
            isUserInteractionEnabled = false
            guard let scene = window?.windowScene else { return }

            if observedScene !== scene {
                NotificationCenter.default.removeObserver(self, name: UIScene.didActivateNotification, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate),
                                                       name: UIScene.didActivateNotification, object: scene)
                observedScene = scene
            }

            scene.titlebar?.titleVisibility = .hidden

            // The Mac interface idiom uses display points. Leave room for the menu bar,
            // Dock, and window chrome; the system resolves final placement on this display.
            let display = scene.screen.bounds.size
            guard display.width > 80, display.height > 120 else { return }
            let available = CGSize(width: display.width - 80, height: display.height - 120)
            scene.sizeRestrictions?.minimumSize = CGSize(width: min(960, available.width),
                                                          height: min(680, available.height))

            guard scene.activationState == .foregroundActive,
                  !requestedInitialSize,
                  !UserDefaults.standard.bool(forKey: Self.initialSizeKey) else { return }

            requestedInitialSize = true
            UserDefaults.standard.set(true, forKey: Self.initialSizeKey)

            // A restored full-screen window already reflects the user's preferred size.
            guard !scene.isFullScreen else { return }
            let current = scene.effectiveGeometry.systemFrame
            guard !current.isNull, !current.isEmpty else {
                requestedInitialSize = false
                UserDefaults.standard.removeObject(forKey: Self.initialSizeKey)
                return
            }

            let preferred = CGSize(width: min(1320, available.width), height: min(860, available.height))
            // Enlarge the earlier default without shrinking a window the user already expanded.
            let size = CGSize(width: max(current.width, preferred.width),
                              height: max(current.height, preferred.height))
            guard size != current.size else { return }

            // Preserve the system's chosen display and top-left position. macOS constrains
            // this request to the visible desktop, including arrangements with multiple displays.
            let preferences = UIWindowScene.GeometryPreferences.Mac(systemFrame: CGRect(origin: current.origin, size: size))
            scene.requestGeometryUpdate(preferences) { _ in
                // Allow a later launch to try again if the system rejected this request.
                // Never resize repeatedly while the person is using this window.
                UserDefaults.standard.removeObject(forKey: Self.initialSizeKey)
            }
        }

        @objc private func sceneDidActivate() { configure() }
    }
}
#endif
