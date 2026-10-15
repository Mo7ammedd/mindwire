import SwiftUI

/// The same native disclosure for every agent's normalized file edit.
struct ToolDiffCard: View {
    let edit: FileEdit
    var isError = false
    @Environment(\.chatProjectPath) private var projectPath
    @State private var expanded = false
    @State private var showAll = false
    private static let lineCap = 8

    init(edit: FileEdit, isError: Bool = false, initiallyExpanded: Bool = false) {
        self.edit = edit
        self.isError = isError
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var lines: [DiffLine] {
        if let patch = edit.unifiedDiff, !patch.isEmpty { return DiffParser.parsePatch(patch) }
        return edit.hunks.flatMap { DiffParser.editDiff(old: $0.old, new: $0.new) }
    }

    var body: some View {
        let all = lines
        let adds = all.filter { $0.kind == .addition }.count
        let dels = all.filter { $0.kind == .deletion }.count
        let shown = showAll ? all : Array(all.prefix(Self.lineCap))
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if all.isEmpty {
                    Text(t("chat.diff.unavailable")).font(.caption).foregroundStyle(.secondary)
                } else {
                    DiffLinesView(lines: shown, compact: true)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    if all.count > Self.lineCap {
                        Button(t(showAll ? "chat.diff.showLess" : "chat.diff.showMore",
                                 ["n": "\(all.count - Self.lineCap)"])) { showAll.toggle() }
                            .font(.caption).tint(.secondary)
                    }
                }
            }
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.sm)
        } label: {
            HStack(spacing: Spacing.sm) {
                FileIcon(name: (edit.path as NSString).lastPathComponent, size: ChatContentStyle.iconSize)
                    .frame(width: ChatContentStyle.iconWidth, height: ChatContentStyle.iconWidth).accessibilityHidden(true)
                Text(WorkspaceFileLink(path: edit.path).displayPath(relativeTo: projectPath))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Spacing.sm)
                if isError {
                    AppIcon(.warning, size: ChatContentStyle.iconSize).foregroundStyle(Palette.danger)
                } else if !all.isEmpty {
                    GitDiffStats(additions: adds, deletions: dels).fixedSize()
                }
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .font(.subheadline)
        .tint(.secondary)
        .accessibilityIdentifier("chat.fileEdit.\(edit.path)")
    }
}
