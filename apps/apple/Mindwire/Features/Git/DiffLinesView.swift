import SwiftUI

/// Diff previews keep code text neutral, with shared red/green markers and line fills.
/// `DiffPalette` keeps previews, counts, and the code editor in sync.
struct DiffLinesView: View {
    let lines: [DiffLine]
    /// Compact = the in-chat card look: no line-number gutters, neutral code text with only the
    /// `+`/`−` marker colored, and the shared diff fill — much cleaner than the full git-diff view in a
    /// narrow bubble. Default off keeps Source Control's numbered diff unchanged.
    var compact = false
    /// Source Control previews show a few single-line excerpts; chat diffs keep wrapping normally.
    var lineLimit: Int? = nil
    /// Bounded list previews use exact line heights and an eager stack inside the recycled row.
    var rowHeight: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var palette: EditorTheme.DiffPalette { EditorTheme.diffPalette(dark: colorScheme == .dark) }

    var body: some View {
        Group {
            if rowHeight != nil {
                VStack(alignment: .leading, spacing: 0) { rows }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) { rows }
            }
        }
        .padding(.vertical, compact ? 0 : Spacing.xs)
    }

    private var rows: some View { ForEach(lines) { line in row(line) } }

    @ViewBuilder
    private func row(_ line: DiffLine) -> some View {
        if line.kind == .hunk {
            Text(line.text)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(lineLimit)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, rowHeight == nil ? Spacing.xs : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: rowHeight)
                .background(Color.secondary.opacity(0.10))
        } else {
            HStack(alignment: .top, spacing: 0) {
                if !compact {
                    gutter(line.oldNumber)
                    gutter(line.newNumber)
                }
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Text(sign(line.kind))
                        .fontWeight(.semibold)
                        .foregroundStyle(signColor(line.kind))
                        .frame(width: 8, alignment: .leading)
                    Text(line.text.isEmpty ? " " : line.text)
                        .lineLimit(lineLimit)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.leading, Spacing.sm)
                .padding(.trailing, compact ? Spacing.sm : Spacing.md)
            }
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .background(background(line.kind))
            .overlay(alignment: .leading) {
                if line.kind == .addition || line.kind == .deletion {
                    Rectangle().fill(signColor(line.kind)).frame(width: 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
    }

    /// Color belongs to the marker; both preview layouts keep the code text neutral.
    private func signColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color(uiColor: palette.addedText)
        case .deletion: return Color(uiColor: palette.removedText)
        default: return .secondary
        }
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(.caption2, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, Spacing.xs)
    }

    private func sign(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "−"
        default: return " "
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color(uiColor: palette.addedBg)
        case .deletion: return Color(uiColor: palette.removedBg)
        default: return .clear
        }
    }
}


/// Reserve the same viewport before and after loading so recycled list rows never move the reader.
struct GitDiffPreview: View {
    let model: GitModel
    let change: GitFileChange
    let staged: Bool
    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = 18
    private var preview: GitDiffPreviewState { model.preview(path: change.path, staged: staged) }
    private var request: GitDiffRequest { .init(change: change, staged: staged, revision: model.diffRevision(path: change.path)) }

    var body: some View {
        let state = preview
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Group {
                if !state.lines.isEmpty {
                    DiffLinesView(lines: state.lines, compact: true, lineLimit: 1, rowHeight: lineHeight)
                } else if let message = state.error ?? state.notice {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: lineHeight * CGFloat(GitDiffPreviewState.lineLimit), alignment: .topLeading)
            .clipped()
            HStack(spacing: Spacing.sm) {
                if state.error != nil {
                    Button(t("common.retry")) {
                        Task { await state.load(model: model, request: request, force: true) }
                    }.buttonStyle(.borderless).tint(.primary)
                } else {
                    Text(state.footer ?? " ").foregroundStyle(.secondary).lineLimit(1)
                    if state.isLoading && state.hasResult { ProgressView().controlSize(.mini) }
                }
            }
            .font(.caption)
            .frame(height: lineHeight, alignment: .leading)
        }
        .accessibilityIdentifier("git.preview.\(staged ? "staged" : "working").\(change.path)")
        .transaction { $0.animation = nil }
        .task(id: request) { await state.load(model: model, request: request) }
    }
}
