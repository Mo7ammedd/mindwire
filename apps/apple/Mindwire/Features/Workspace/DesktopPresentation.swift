import SwiftUI
import UIKit

/// Allow rotation only for a presented desktop, and keep an active viewer awake.
/// Per-window registration avoids changing the rest of the app's orientation.
struct DesktopPresentation: UIViewControllerRepresentable {
    var keepAwake: Bool
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.setAwake(keepAwake) }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.close() }

    @MainActor final class Controller: UIViewController {
        private weak var desktopWindow: UIWindow?
        private var wasIdleDisabled: Bool?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let window = view.window, desktopWindow !== window else { return }
            desktopWindow = window
            DesktopOrientations.windows.add(window)
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        func setAwake(_ active: Bool) {
            if active {
                if wasIdleDisabled == nil { wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled }
                UIApplication.shared.isIdleTimerDisabled = true
            } else if let previous = wasIdleDisabled {
                UIApplication.shared.isIdleTimerDisabled = previous; wasIdleDisabled = nil
            }
        }
        func close() {
            setAwake(false)
            guard let window = desktopWindow else { return }
            DesktopOrientations.windows.remove(window)
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            // iPad windows keep their current orientation when a desktop closes.
            if UIDevice.current.userInterfaceIdiom != .pad {
                window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
            desktopWindow = nil
        }
    }
}

@MainActor enum DesktopOrientations {
    static let windows = NSHashTable<UIWindow>.weakObjects()
    static func supported(for window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        if let window, windows.contains(window) { return .allButUpsideDown }
        return .portrait
    }
}
