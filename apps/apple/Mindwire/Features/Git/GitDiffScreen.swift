import Runestone
import SwiftUI

/// Native syntax-highlighted review, with compact context by default and full-file context on demand.
struct GitDiffScreen: View {
    let model: GitModel
    let change: GitFileChange
    let staged: Bool
    var commit: GitCommit? = nil
    var comparison: GitPullRequestComparison? = nil
    var onReviewFinished: (() -> Void)? = nil
    var onOpenChat: ((String, String) -> Void)? = nil
    var desktopInline = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.embeddedWorkspaceTool) private var embedded
    @Environment(\.desktopProjectContext) private var projectContext
    @Environment(AppModel.self) private var app
    @AppStorage("mindwire.editor.fontSize") private var fontSize: Double = 13
    @AppStorage("mindwire.editor.wrapLines") private var wrapLines = false
    @StateObject private var editor = EditorHandle()
    @State private var fullContext = false
    @State private var showingSettings = false
    @State private var buffer = ""
    @State private var tints: [Int: DiffTint] = [:]
    @State private var changes: [NSRange] = []
    @State private var selectedChange: Int?
    @State private var additions = 0
    @State private var deletions = 0
    @State private var loading = true
    @State private var hasResult = false
    @State private var completedRequest: GitDiffRequest?
    @State private var loadGeneration = 0
    @State private var loadError: String?
    @State private var unsupported: String?
    @State private var truncated = false
    @State private var working = false
    @State private var discardConfirm = false
    @State private var failure: String?
    @State private var selection: String?
    @State private var agentPick: SendToAgentPayload?

    private var current: GitFileChange? {
        if isReadOnly { return change }
        return model.allChanges.first {
            $0.path == change.path && (staged ? $0.isStaged : $0.hasUnstagedChange || $0.isUntracked || $0.isConflicted)
        }
    }

    private var isReadOnly: Bool { commit != nil || comparison != nil }

    private var focusedChange: NSRange? {
        guard let selectedChange, changes.indices.contains(selectedChange) else { return nil }
        return changes[selectedChange]
    }

    private var diffRequest: GitDiffRequest {
        GitDiffRequest(change: current ?? change, staged: staged, revision: isReadOnly ? 0 : model.diffRevision(path: change.path),
                       fullContext: fullContext, commitID: comparison?.id ?? commit?.id)
    }

    var body: some View {
        let request = diffRequest
        content
        .navigationTitle(change.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .bottomBar)
        .toolbar(ApplePlatform.isDesktop ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !ApplePlatform.isDesktop {
                AppToolbarItem(placement: .topBarTrailing) { optionsMenu }
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            if ApplePlatform.isDesktop { desktopToolbar } else { fileContext }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if model.projectId != nil, onOpenChat != nil, let selection, !selection.isEmpty {
                if !ApplePlatform.isDesktop {
                    SendCodeToAgentButton { sendSelection(selection) }
                        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
                }
            } else if !isReadOnly && !ApplePlatform.isDesktop { reviewBar }
        }
        .sheet(isPresented: $showingSettings) { EditorSettingsView() }
        .sendCodeToAgent($agentPick, projectId: model.projectId, onOpenChat: onOpenChat)
        .alert(t("git.discard.title"), isPresented: $discardConfirm) {
            Button(t("git.discard"), role: .destructive) { Task { await apply(discard: true) } }
            Button(t("common.cancel"), role: .cancel) {}
        } message: { Text(t("git.discard.body", ["name": change.name])) }
        .alert(t("git.operation.failed"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button(t("common.ok"), role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .task(id: request) { await load(request) }
        .ignoresSafeArea(.container, edges: ApplePlatform.isDesktop ? .top : [])
    }

    private var reviewContext: String {
        comparison.map { t("git.pr.comparisonBase", ["base": $0.baseBranch]) }
            ?? commit.map { t("git.history.commitContext", ["id": $0.shortID]) }
            ?? t(staged ? "git.staged" : "git.changes")
    }

    private var desktopNavigationHidden: Bool {
        desktopInline && embedded && projectContext != nil && !app.desktopToolSidebarVisible
    }

    private var desktopToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if desktopNavigationHidden {
                    DesktopNavigationToggle()
                    Button { app.showProjects() } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28)
                    }
                    .buttonStyle(AssistantDesktopButtonStyle()).help("Back to Projects")
                    .accessibilityLabel("Back to Projects").accessibilityIdentifier("desktop.project.back")
                } else if !desktopInline {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28)
                    }
                    .buttonStyle(AssistantDesktopButtonStyle()).help(t("common.back"))
                    .accessibilityLabel(t("common.back"))
                }
                FileIcon(name: change.name, size: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(change.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if hasResult { GitDiffStats(additions: additions, deletions: deletions) }
                        if loading && hasResult { ProgressView().controlSize(.mini) }
                    }
                    Text(change.path == change.name ? reviewContext : change.path)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .help("\(change.path) · \(reviewContext)")
                .frame(maxWidth: .infinity, alignment: .leading)
                changeNavigation
                if !isReadOnly { stageButton.buttonStyle(DesktopActionButtonStyle()) }
                optionsMenu.frame(width: 28, height: 28)
            }
            .padding(.horizontal, 16).padding(.leading, desktopNavigationHidden ? 76 : 0)
            .frame(height: AssistantDesktopStyle.headerHeight)
            contextNotices.padding(.horizontal, 16)
            Rectangle().fill(AssistantDesktopStyle.separator).frame(height: 0.5)
        }
        .background(AssistantDesktopStyle.canvas)
    }

    private var optionsMenu: some View {
        AppMenu {
            Section(t("git.diff.context")) {
                Picker(t("git.diff.context"), selection: $fullContext) {
                    Text(t("git.diff.changesOnly")).tag(false)
                    Text(t("git.diff.fullFile")).tag(true)
                }
            }
            Section {
                Toggle(t("editor.wrapLines"), isOn: $wrapLines)
                Button { showingSettings = true } label: { Label(t("editor.settings"), icon: .type) }
                Button { UIPasteboard.general.string = change.path } label: { Label(t("editor.info.copyPath"), icon: .copy) }
                if ApplePlatform.isDesktop, model.projectId != nil, onOpenChat != nil,
                   let selection, !selection.isEmpty {
                    Button { sendSelection(selection) } label: { Label(t("editor.sendToAgent"), icon: Icon.chat) }
                }
            }
            if !isReadOnly && !staged && !change.isConflicted {
                Section {
                    DestructiveButton(t("git.discard"), icon: Icon.trash) { discardConfirm = true }
                        .disabled(working || model.isMutating || current == nil)
                        .accessibilityIdentifier("git.diff.discard")
                }
            }
        } label: { AppIcon(.more, size: ApplePlatform.isDesktop ? 16 : 20) }
        .tint(.primary).accessibilityLabel(t("git.diff.options"))
        .accessibilityIdentifier("git.diff.options")
    }

    private var fileContext: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(change.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    HStack(spacing: Spacing.sm) {
                        Text(reviewContext)
                            .font(.caption).foregroundStyle(.secondary)
                        if hasResult { GitDiffStats(additions: additions, deletions: deletions) }
                        if loading && hasResult { ProgressView().controlSize(.mini) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                changeNavigation
            }
            .frame(minHeight: 44)
            contextNotices
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
    }

    @ViewBuilder private var contextNotices: some View {
        if change.isConflicted {
            Label(t("git.diff.conflict"), icon: .warning)
                .font(.caption).foregroundStyle(.secondary)
        }
        if truncated {
            Label(t("git.diff.truncated"), icon: .fileMore)
                .font(.caption).foregroundStyle(.secondary)
        }
        if hasResult, let loadError {
            HStack {
                Text(loadError).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: Spacing.sm)
                Button(t("common.retry")) { Task { await load(diffRequest, force: true) } }
                    .font(.caption)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if loading && !hasResult {
            ProgressView(t("git.diff.loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if unsupported != nil || !hasResult {
            ContentUnavailableView {
                Label(t("git.diff.unavailable"), icon: .fileWarning)
            } description: {
                Text(unsupported ?? loadError ?? t("git.loadFailed"))
            } actions: {
                Button(t("common.retry")) { Task { await load(diffRequest, force: true) } }.buttonStyle(.glass)
            }
        } else if buffer.isEmpty {
            GitEmptyState(title: t("git.diff.noChanges"), message: t("git.diff.noChanges.body"))
                .padding(Spacing.lg)
                .frame(maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                CodeEditorView(text: $buffer, language: CodeLanguage.language(for: change.name),
                               fontSize: CGFloat(fontSize), isDark: colorScheme == .dark,
                               wrapLines: wrapLines, isEditable: false, diffTints: tints,
                               focusedRange: focusedChange, contentSafeAreaInsets: geometry.safeAreaInsets,
                               onSelectionChange: { selection = $0 }, handle: editor)
                    // Native edge effects need code beneath the bars. Insets belong to the scroll
                    // content, so the first/last lines and change navigation remain unobscured.
                    .ignoresSafeArea(.all, edges: .vertical)
                    .accessibilityIdentifier("git.diff.editor")
            }
        }
    }

    private var reviewBar: some View {
        HStack(spacing: Spacing.sm) {
            reviewActions
        }
        .controlSize(.regular)
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
    }

    @ViewBuilder private var changeNavigation: some View {
        if !changes.isEmpty {
            if ApplePlatform.isDesktop {
                changeNavigationControls.buttonStyle(AssistantDesktopButtonStyle()).foregroundStyle(.secondary)
            } else {
                changeNavigationControls.buttonStyle(.glass).tint(.primary)
            }
        }
    }

    private var changeNavigationControls: some View {
        HStack(spacing: Spacing.xs) {
                Button { revealChange((selectedChange ?? 1) - 1) } label: {
                    AppIcon(.chevronUp, size: ApplePlatform.isDesktop ? 13 : 20).frame(minWidth: 28, minHeight: 28)
                }
                .help(t("git.diff.previous"))
                .disabled(loading || selectedChange == nil || selectedChange == 0)
                .accessibilityLabel(t("git.diff.previous"))
                .accessibilityIdentifier("git.diff.previous")
                Text(selectedChange.map { "\($0 + 1)/\(changes.count)" }
                     ?? "\(changes.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    .accessibilityLabel(t(changes.count == 1 ? "git.diff.changeCount.one" : "git.diff.changeCount",
                                          ["count": "\(changes.count)"]))
                Button { revealChange((selectedChange ?? -1) + 1) } label: {
                    AppIcon(.chevronDown, size: ApplePlatform.isDesktop ? 13 : 20).frame(minWidth: 28, minHeight: 28)
                }
                .help(t("git.diff.next"))
                .disabled(loading || selectedChange == changes.count - 1)
                .accessibilityLabel(t("git.diff.next"))
                .accessibilityIdentifier("git.diff.next")
        }
    }

    @ViewBuilder private var reviewActions: some View {
        if !staged && !change.isConflicted {
            Button { discardConfirm = true } label: {
                Text(t("git.discard")).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.glass).tint(.primary)
                .disabled(loading || working || model.isMutating || current == nil)
                .accessibilityIdentifier("git.diff.discard")
        }
        stageButton.buttonStyle(.glassProminent)
    }

    private var stageButton: some View {
        Button { Task { await apply(discard: false) } } label: {
            Text(t(staged ? "git.unstage" : "git.stage"))
                .foregroundStyle(ApplePlatform.isDesktop ? Color.primary : Palette.onAccent)
                .opacity(working ? 0 : 1)
                .frame(maxWidth: ApplePlatform.isDesktop ? nil : .infinity)
                .overlay { if working { ProgressView().controlSize(.mini) } }
        }
        .disabled(loading || working || model.isMutating || current == nil)
        .accessibilityIdentifier("git.diff.stage")
    }

    private func sendSelection(_ code: String) {
        let path = model.status?.root.map { ($0 as NSString).appendingPathComponent(change.path) } ?? change.path
        let patch = editor.textView.flatMap {
            DiffParser.selectedPatch(in: buffer, tints: tints, range: $0.selectedRange)
        } ?? code
        agentPick = SendToAgentPayload(path: path, code: patch,
                                       context: commit.map { t("git.history.commitContext", ["id": $0.id]) } ?? t(staged ? "git.staged" : "git.changes"), format: "diff")
    }

    private func revealChange(_ index: Int) {
        guard changes.indices.contains(index) else { return }
        selectedChange = index
        editor.textView?.scrollRangeToVisible(NSRange(location: changes[index].location, length: 0))
    }

    private func apply(discard: Bool) async {
        guard !isReadOnly, !working, !model.isMutating, current != nil else { return }
        working = true
        let succeeded: Bool
        if discard { succeeded = await model.discard([change.path]) }
        else if staged { succeeded = await model.unstage([change.path]) }
        else { succeeded = await model.stage([change.path]) }
        working = false
        if succeeded {
            if let onReviewFinished { onReviewFinished() }
            else { dismiss() }
        }
        else if let error = model.error { failure = error }
    }

    private func load(_ request: GitDiffRequest, force: Bool = false) async {
        guard !Task.isCancelled, force || completedRequest != request else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        loadError = nil
        defer { if generation == loadGeneration { loading = false } }
        do {
            guard current != nil else {
                buffer = ""; tints = [:]; changes = []; selectedChange = nil; selection = nil
                additions = 0; deletions = 0; truncated = false; unsupported = nil
                hasResult = true; completedRequest = request
                return
            }
            let result = try await DiffParser.lines(model: model, change: request.change, staged: request.staged,
                                                   unified: request.fullContext ? 1_000_000 : nil, commit: commit, comparison: comparison)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            let built = DiffParser.inlineDiff(result.lines, showsHunkHeaders: !request.fullContext)
            // Keep the native editor, scroll position and selection for unchanged content.
            // A refresh never replaces an already visible editor with a loading screen.
            if buffer != built.text || tints != built.tints {
                selectedChange = nil
                selection = nil
                buffer = built.text
                tints = built.tints
            }
            changes = built.changes
            additions = result.additions; deletions = result.deletions
            truncated = result.truncated
            unsupported = result.binary ? t("git.diff.binary") : nil
            hasResult = true
            completedRequest = request
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !error.isRequestCancellation else { return }
            loadError = error.localizedDescription
        }
    }
}
