import SwiftUI
import UIKit

struct GitDiffRoute: Hashable {
    let change: GitFileChange
    let staged: Bool
    var commit: GitCommit? = nil
    var comparison: GitPullRequestComparison? = nil
    var selectionID: String { "\(comparison?.id ?? commit?.id ?? "working"):\(staged):\(change.path)" }
}

/// Empty Git lists use the same quiet typography, without decorative symbols or cards.
struct GitEmptyState: View {
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Text(title).font(.headline)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

/// The same compact, actionable file row in Changes, Commit, and commit history.
struct GitFileRow: View {
    let model: GitModel
    let change: GitFileChange
    let staged: Bool
    var commit: GitCommit? = nil
    var comparison: GitPullRequestComparison? = nil
    var review = false
    var onDiscard: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let onOpen {
                Button(action: onOpen) { fileLabel }
                    .buttonStyle(.plain)
            } else {
                NavigationLink(value: GitDiffRoute(change: change, staged: staged, commit: commit, comparison: comparison)) { fileLabel }
            }
            if review && commit == nil && comparison == nil { GitDiffPreview(model: model, change: change, staged: staged) }
        }
        .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.lg,
                                 bottom: Spacing.xs, trailing: Spacing.lg))
        .listRowBackground(isSelected ? Palette.accent.opacity(0.10)
                           : ApplePlatform.isDesktop ? Color.clear : Color(.secondarySystemGroupedBackground))
        .listRowSeparator(ApplePlatform.isDesktop ? .hidden : .automatic)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(GitFileActions(model: model, change: change, staged: staged, commit: commit,
                                 readOnly: comparison != nil, onDiscard: onDiscard))
    }

    private var fileLabel: some View {
        GitChangeRow(change: change, staged: staged,
                     pendingAction: commit == nil && comparison == nil ? model.fileAction(path: change.path, staged: staged) : nil)
            .contentShape(.rect)
    }
}

/// Shared actions for regular change rows and the file explorer's tree rows.
struct GitFileActions: ViewModifier {
    let model: GitModel
    let change: GitFileChange
    let staged: Bool
    var commit: GitCommit? = nil
    var readOnly = false
    var onDiscard: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.appContextMenu { actions }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if commit == nil && !readOnly {
                if let onDiscard, !staged && !change.isConflicted {
                    Button(role: .destructive, action: onDiscard) { Text(t("git.discard")) }
                        .accessibilityLabel(t("git.discard"))
                        .disabled(model.isMutating)
                }
                Button(action: toggleStaged) {
                    Text(t(staged ? "git.unstage" : "git.stage"))
                }
                .accessibilityLabel(t(staged ? "git.unstage" : "git.stage"))
                .tint(.gray).disabled(model.isMutating)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if commit == nil && !readOnly {
            Button(action: toggleStaged) {
                Label(t(staged ? "git.unstage" : "git.stage"), icon: staged ? .minus : .plus)
            }
            .disabled(model.isMutating)
        }
        Button { UIPasteboard.general.string = change.path } label: {
            Label(t("editor.info.copyPath"), icon: .copy)
        }
        if commit == nil, !readOnly, !staged && !change.isConflicted, let onDiscard {
            DestructiveButton(t("git.discard"), icon: Icon.trash, action: onDiscard).disabled(model.isMutating)
        }
    }

    private func toggleStaged() {
        Task {
            if staged { await model.unstage([change.path]) }
            else { await model.stage([change.path]) }
        }
    }
}

/// File identity and change counts stay consistent in the list, review, and commit sheet.
struct GitChangeRow: View {
    let change: GitFileChange
    let staged: Bool
    var pendingAction: GitAction? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 22
    private var glyphSize: CGFloat { ApplePlatform.isDesktop ? 17 : iconSize }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            glyph
            title
            Spacer(minLength: Spacing.sm)
            if !typeSize.isAccessibilitySize { details }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(pendingAction?.title ?? "")
        .accessibilityIdentifier("git.file.\(staged ? "staged" : "working").\(change.path)")
    }

    private var glyph: some View {
        FileIcon(name: change.name, size: glyphSize)
            .frame(width: glyphSize + 2, height: glyphSize + 2)
            .opacity(pendingAction == nil ? 1 : 0)
            .overlay {
                if let pendingAction {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(pendingAction.title)
                        .accessibilityIdentifier("git.fileProgress.\(change.path)")
                }
            }
            .accessibilityHidden(true)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(change.name)
                .font(ApplePlatform.isDesktop ? .system(size: 12, weight: .medium) : .subheadline.weight(.medium))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
            if let location = change.reviewLocation {
                Text(location).font(ApplePlatform.isDesktop ? .system(size: 10) : .caption).foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1).truncationMode(.middle)
            }
            if typeSize.isAccessibilitySize { details }
        }
    }

    private var details: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
            if let stat = change.lineStat(staged: staged) {
                GitDiffStats(additions: stat.additions, deletions: stat.deletions)
            }
            Text(change.reviewStatus(staged: staged))
                .font(ApplePlatform.isDesktop ? .system(size: 10) : .caption)
                .foregroundStyle(change.isConflicted ? .red : .secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct GitDiffStats: View {
    let additions: Int
    let deletions: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = EditorTheme.diffPalette(dark: colorScheme == .dark)
        HStack(spacing: Spacing.sm) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(Color(uiColor: palette.addedText)) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(Color(uiColor: palette.removedText)) }
        }
        .font(ApplePlatform.isDesktop ? .system(size: 11, weight: .medium) : .caption.weight(.medium)).monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("git.lineCounts", ["added": "\(additions)", "removed": "\(deletions)"]))
    }
}

struct GitRepositorySummary: View {
    let model: GitModel
    let chooseBranch: () -> Void
    var showHistory: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: chooseBranch) {
                HStack(spacing: Spacing.sm) {
                    AppIcon(Icon.repo, size: ApplePlatform.isDesktop ? 14 : 17).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).accessibilityHidden(true)
                    Text(model.status?.branch ?? t("git.detached"))
                        .font(ApplePlatform.isDesktop ? .system(size: 12, weight: .medium) : .subheadline.weight(.medium))
                        .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                    AppIcon(.chevronDown, size: ApplePlatform.isDesktop ? 10 : 14)
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    if let status = model.status {
                        HStack(spacing: Spacing.sm) {
                            if status.ahead > 0 {
                                HStack(spacing: 2) { AppIcon(.arrowUp); Text("\(status.ahead)") }
                            }
                            if status.behind > 0 {
                                HStack(spacing: 2) { AppIcon(.arrowDown); Text("\(status.behind)") }
                            }
                        }
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: ApplePlatform.isDesktop ? 28 : 36)
            }
            .buttonStyle(.plain)
            .accessibilityHint(t("git.branches.switch"))
            .accessibilityIdentifier("git.chooseBranch")
            Spacer(minLength: Spacing.md)
            if let showHistory {
                Button(action: showHistory) {
                    if ApplePlatform.isDesktop {
                        AppIcon(.history, size: 14).frame(width: 28, height: 28)
                    } else {
                        Text(t("git.history.shortTitle")).font(.subheadline).fixedSize().frame(minHeight: 44)
                    }
                }
                .buttonStyle(.plain).tint(.primary)
                .help(t("git.history.title"))
                .accessibilityLabel(t("git.history.title"))
                .accessibilityIdentifier("git.openHistory")
            }
        }
    }
}

struct GitRepositoryChangeSummary: View {
    let model: GitModel

    var body: some View {
        let stats = model.allChanges.reduce(into: GitLineStat()) { result, file in
            result.additions += (file.staged?.additions ?? 0) + (file.unstaged?.additions ?? 0)
            result.deletions += (file.staged?.deletions ?? 0) + (file.unstaged?.deletions ?? 0)
        }
        HStack {
            Text(t(model.allChanges.count == 1 ? "git.filesChanged.one" : "git.filesChanged",
                   ["count": "\(model.allChanges.count)"]))
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.sm)
            GitDiffStats(additions: stats.additions, deletions: stats.deletions)
        }
        .font(ApplePlatform.isDesktop ? .system(size: 11) : .caption)
    }
}

/// Progress and command output use the same native sections in either review mode.
struct GitOperationSections: View {
    let model: GitModel
    @Environment(\.serviceUpdatePresentation) private var servicePresentation

    var body: some View {
        if let operation = model.activeAction, !operation.isFileAction {
            Section {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(operation.title).font(.subheadline)
                    Spacer()
                    if model.activeOperation?.isActive == true {
                        Button(t("common.cancel"), role: .destructive) { Task { await model.cancelOperation() } }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        if model.authenticationRequired {
            GitAuthenticationRecoverySection(model: model)
        } else if let error = model.error {
            Section {
                DisclosureGroup {
                    Text(error).font(.footnote).textSelection(.enabled)
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label(t(model.serviceRecoveryNeeded ? "git.serviceRecovery.title" : "git.operation.failed.title"), icon: .warning)
                            .font(.subheadline).foregroundStyle(.red)
                        Text(model.serviceRecoveryNeeded ? t("git.serviceRecovery") : error)
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if model.serviceRecoveryNeeded, let servicePresentation {
                    HStack {
                        Button(t("workspace.daemon.title")) { servicePresentation.show(workspace: model.workspace) }
                            .accessibilityIdentifier("git.serviceRecovery")
                        Spacer(minLength: Spacing.md)
                        Button(t("common.retry")) { Task { await model.refresh() } }
                            .disabled(model.isMutating)
                    }
                    .buttonStyle(.borderless)
                }
                if model.hasPendingOperation && !model.isMutating {
                    Button(t("git.operation.retry")) { Task { await model.retryPendingOperation() } }
                }
            }
            .tint(.primary)
        } else if model.hasPendingOperation && !model.isMutating {
            Section { Button(t("git.operation.retry")) { Task { await model.retryPendingOperation() } } }
        }
        if let output = model.remoteOutput, !output.isEmpty, model.error == nil {
            Section {
                DisclosureGroup(model.operationNotice ?? t("git.operation.output")) {
                    Text(output).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.subheadline)
            }
            .tint(.primary)
        } else if let notice = model.operationNotice, model.error == nil {
            Section { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

/// Reuses the existing project/workspace connection editor. Choosing an account
/// never resubmits a Git write; the user reviews current state before retrying.
struct GitAuthenticationRecoverySection: View {
    let model: GitModel

    var body: some View {
        Section {
            DisclosureGroup {
                if let error = model.error {
                    Text(error).font(.footnote).textSelection(.enabled)
                }
            } label: {
                Label(t("git.auth.required"), icon: .key)
                    .font(.subheadline)
            }
            NavigationLink {
                GitAccessSettingsScreen(workspaceId: model.workspaceId, projectId: model.projectId)
            } label: {
                Text(t("github.access.title"))
            }
            .disabled(model.isMutating)
            .accessibilityIdentifier("git.authentication.recover")
        } footer: {
            Text(t("git.auth.hint"))
        }
        .tint(.primary)
    }
}

extension GitFileChange {
    var reviewLocation: String? {
        if let origPath, origPath != path { return t("git.renamedFrom", ["path": origPath]) }
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }

    func reviewStatus(staged: Bool) -> String {
        if isConflicted { return t("git.status.conflict") }
        if isUntracked { return t("git.status.new") }
        switch staged ? index : worktree {
        case "A": return t("git.status.added")
        case "D": return t("git.status.deleted")
        case "R": return t("git.status.renamed")
        case "C": return t("git.status.copied")
        case "T": return t("git.status.typeChanged")
        default: return t("git.status.modified")
        }
    }
}

struct GitDiffRequest: Hashable {
    let change: GitFileChange
    let staged: Bool
    let revision: Int
    var fullContext = false
    var commitID: String? = nil
}
