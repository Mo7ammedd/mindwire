import SwiftUI

/// Dimensions follow the available window, including Split View and Stage Manager.
enum AdaptiveLayout {
    static let readableWidth: CGFloat = 780
    static let minimumColumnWidth: CGFloat = 840

    static func usesColumns(width: CGFloat, regular: Bool, accessibility: Bool = false) -> Bool {
        regular && width >= (accessibility ? 1_100 : minimumColumnWidth)
    }

    static func sidebarWidth(in width: CGFloat) -> CGFloat {
        min(340, max(296, width * 0.29))
    }
}

extension View {
    /// Keep forms and single-column lists comfortable in a wide detail pane.
    func readablePane() -> some View {
        frame(maxWidth: AdaptiveLayout.readableWidth)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
    }

    /// Tool workspaces need the page-sized iPad sheet; short forms keep their native form size.
    func workspaceToolPresentation() -> some View {
        presentationSizing(.page)
    }
}
