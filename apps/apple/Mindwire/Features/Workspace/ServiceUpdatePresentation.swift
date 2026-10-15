import SwiftUI

enum ServiceUpdateDestination: Identifiable {
    case all
    case workspace(Workspace)

    var id: String {
        switch self {
        case .all: "all"
        case .workspace(let workspace): "workspace:\(workspace.id)"
        }
    }

    var workspace: Workspace? {
        if case .workspace(let workspace) = self { workspace } else { nil }
    }
}

@MainActor @Observable
final class ServiceUpdatePresentation {
    var sheet: ServiceUpdateDestination?

    func show(workspace: Workspace? = nil) {
        guard sheet == nil else { return }
        sheet = workspace.map(ServiceUpdateDestination.workspace) ?? .all
    }
}

private struct ServiceUpdatePresentationKey: EnvironmentKey {
    static let defaultValue: ServiceUpdatePresentation? = nil
}

extension EnvironmentValues {
    var serviceUpdatePresentation: ServiceUpdatePresentation? {
        get { self[ServiceUpdatePresentationKey.self] }
        set { self[ServiceUpdatePresentationKey.self] = newValue }
    }
}

/// The screen owns presentation. List sections and menu labels may be replaced while
/// cached health, installation progress, or the workspace inventory changes.
private struct ServiceUpdatePresentationModifier: ViewModifier {
    let repository: WorkspaceRepository
    let coordinator: DaemonWorkCoordinator
    @State var presentation: ServiceUpdatePresentation

    func body(content: Content) -> some View {
        content
            .environment(\.serviceUpdatePresentation, presentation)
            .sheet(item: $presentation.sheet) { destination in
                ServiceUpdateInfoSheet(workspace: destination.workspace,
                    repository: repository, coordinator: coordinator)
            }
    }
}

extension View {
    @MainActor
    func serviceUpdatePresentation(repository: WorkspaceRepository? = nil,
                                   coordinator: DaemonWorkCoordinator? = nil,
                                   presentation: ServiceUpdatePresentation? = nil) -> some View {
        modifier(ServiceUpdatePresentationModifier(repository: repository ?? .shared,
            coordinator: coordinator ?? .shared, presentation: presentation ?? ServiceUpdatePresentation()))
    }
}
