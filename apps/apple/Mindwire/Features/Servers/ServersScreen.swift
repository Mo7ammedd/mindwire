// Restored Settings routes resolve to the same inventory as the Computers tab.
import SwiftUI

struct ServersScreen: View {
    var repository: WorkspaceRepository = .shared

    var body: some View {
        WorkspacesScreen(repository: repository)
    }
}
