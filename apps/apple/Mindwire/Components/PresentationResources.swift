import SwiftUI

/// Release owned connections when the presentation is removed, not when a pushed screen or
/// another sheet temporarily covers it. Keep this in StateObject for the presentation's lifetime.
@MainActor
final class PresentationResources: ObservableObject {
    var cleanup: (@MainActor () async -> Void)?

    deinit {
        if let cleanup { Task { @MainActor in await cleanup() } }
    }
}
