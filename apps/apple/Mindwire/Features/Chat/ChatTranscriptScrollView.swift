import SwiftUI
import UIKit

/// A user disclosure changes the layout without asking to follow the bottom of the transcript.
struct ChatTranscriptExpansion<ID: Hashable>: Equatable {
    let rowID: ID
    var revision = UUID()
}

/// A recycled, self-sizing row per response part. UIKit owns scrolling and measurement; the same
/// SwiftUI markdown and tool views are used for live output, saved messages, and chat previews.
struct ChatTranscriptScrollView<Row: Identifiable & Equatable, Content: View>: View {
    let rows: [Row]
    let isRunning: Bool
    var isRestoring = false
    var loadingOlder = false
    var hasNewerHistory = false
    var restorationRevision = 0
    var latestRequestRevision = 0
    var expansion: ChatTranscriptExpansion<Row.ID>? = nil
    var onLoadOlder: (() async -> Void)? = nil
    var onFollowingChanged: ((Bool) -> Void)? = nil
    var onJumpToLatest: (() -> Void)? = nil
    var onDismissKeyboard: (() -> Void)? = nil
    @ViewBuilder var content: (Row) -> Content
    @State private var showsJump = false
    @State private var jumpRevision = 0

    var body: some View {
        GeometryReader { geometry in
            ChatTranscriptTable(rows: rows, isRunning: isRunning, isRestoring: isRestoring,
                                loadingOlder: loadingOlder,
                                restorationRevision: restorationRevision, jumpRevision: jumpRevision,
                                latestRequestRevision: latestRequestRevision,
                                expansion: expansion,
                                safeAreaInsets: geometry.safeAreaInsets,
                                onLoadOlder: onLoadOlder, onDismissKeyboard: onDismissKeyboard,
                                onFollowingChanged: { showsJump = !$0; onFollowingChanged?($0) }, content: content)
                // The native edge effects need content underneath the bars. Keep the outer viewport
                // safe so floating controls stay above the composer; inset only the table's content.
                .ignoresSafeArea(.all, edges: .vertical)
        }
            .overlay(alignment: .bottomTrailing) {
                if showsJump || hasNewerHistory {
                    Button { onJumpToLatest?(); jumpRevision += 1 } label: {
                        AppIcon(.arrowDown).padding(Spacing.xs)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .tint(.primary)
                    .accessibilityLabel(t("chat.jumpToLatest"))
                    .padding(Spacing.md)
                }
            }
    }
}

private struct ChatTranscriptTable<Row: Identifiable & Equatable, Content: View>: UIViewRepresentable {
    let rows: [Row]
    let isRunning: Bool
    let isRestoring: Bool
    let loadingOlder: Bool
    let restorationRevision: Int
    let jumpRevision: Int
    let latestRequestRevision: Int
    let expansion: ChatTranscriptExpansion<Row.ID>?
    let safeAreaInsets: EdgeInsets
    let onLoadOlder: (() async -> Void)?
    let onDismissKeyboard: (() -> Void)?
    let onFollowingChanged: (Bool) -> Void
    @ViewBuilder var content: (Row) -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TranscriptTableView {
        let table = TranscriptTableView(frame: .zero, style: .plain)
        table.accessibilityIdentifier = "chat.transcript"
        table.backgroundColor = .clear
        table.topEdgeEffect.style = .soft
        table.bottomEdgeEffect.style = .soft
        table.separatorStyle = .none
        table.allowsSelection = false
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 100
        table.sectionHeaderHeight = 0
        table.sectionFooterHeight = 0
        table.sectionHeaderTopPadding = 0
        table.contentInset = UIEdgeInsets(top: Spacing.lg, left: 0, bottom: Spacing.lg, right: 0)
        table.contentInsetAdjustmentBehavior = .never
        table.automaticallyAdjustsScrollIndicatorInsets = false
        table.keyboardDismissMode = .interactive
        table.alwaysBounceVertical = true
        table.register(TranscriptCell.self, forCellReuseIdentifier: "part")
        context.coordinator.connect(table)
        return table
    }

    func updateUIView(_ table: TranscriptTableView, context: Context) {
        // SwiftUI knows the navigation/composer/keyboard safe area. The expanded UIKit view has a
        // zero safe area of its own, so automatic UIKit adjustment would hide the last line below it.
        let insets = UIEdgeInsets(top: safeAreaInsets.top + Spacing.lg, left: 0,
                                 bottom: safeAreaInsets.bottom + Spacing.lg, right: 0)
        if table.contentInset != insets { table.contentInset = insets }
        table.verticalScrollIndicatorInsets = UIEdgeInsets(top: safeAreaInsets.top, left: 0,
                                                           bottom: safeAreaInsets.bottom, right: 0)
        context.coordinator.update(self, environment: context.environment)
    }

    static func dismantleUIView(_ table: TranscriptTableView, coordinator: Coordinator) {
        coordinator.disconnect()
        table.onLayout = nil
        table.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDelegate, UIGestureRecognizerDelegate {
        private weak var table: TranscriptTableView?
        private var dataSource: UITableViewDiffableDataSource<Int, Row.ID>!
        private var rows: [Row] = []
        private var rowsByID: [Row.ID: Row] = [:]
        private var measuredHeights: [Row.ID: CGFloat] = [:]
        private var parent: ChatTranscriptTable?
        private var environment = EnvironmentValues()
        private var restorationRevision = -1
        private var jumpRevision = 0
        private var latestRequestRevision = 0
        private var expansion: ChatTranscriptExpansion<Row.ID>?
        private var wasRunning = false
        private var followsOutput = true
        private var manualScroll = false
        private var positioning = false
        private var updating = false
        private var snapshotRevision = 0
        private var pinScheduled = false
        private var jumping = false
        private var disclosureAnchor: Anchor?
        private let olderHeader = UIView()
        private let olderIndicator = UIActivityIndicatorView(style: .medium)
        fileprivate var pagingTask: Task<Void, Never>?
        private lazy var keyboardDismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))

        private struct Anchor {
            let id: Row.ID
            let offset: CGFloat
        }

        func connect(_ table: TranscriptTableView) {
            self.table = table
            table.delegate = self
            olderIndicator.accessibilityLabel = "Loading older messages"
            olderIndicator.accessibilityIdentifier = "chat-history-older-loading"
            olderIndicator.isAccessibilityElement = false
            olderIndicator.sizeToFit()
            // Observe a completed tap without cancelling links, disclosures, selection, or scrolling.
            // This recognizer belongs only to the transcript, never the composer or a presented sheet.
            keyboardDismissTap.cancelsTouchesInView = false
            keyboardDismissTap.delaysTouchesBegan = false
            keyboardDismissTap.delaysTouchesEnded = false
            keyboardDismissTap.delegate = self
            keyboardDismissTap.isEnabled = false
            table.addGestureRecognizer(keyboardDismissTap)
            dataSource = UITableViewDiffableDataSource<Int, Row.ID>(tableView: table) { [weak self] table, index, id in
                let cell = table.dequeueReusableCell(withIdentifier: "part", for: index)
                guard let self, let row = self.rowsByID[id], let parent = self.parent else { return cell }
                (cell as? TranscriptCell)?.rowID = AnyHashable(id)
                cell.selectionStyle = .none
                cell.backgroundConfiguration = .clear()
                cell.contentConfiguration = UIHostingConfiguration {
                    parent.content(row)
                        // UIKit supplies current size, appearance, and accessibility traits. Only
                        // app-owned environment values need crossing this hosting boundary.
                        .environment(\.stores, self.environment.stores)
                        .environment(\.desktopWorkspaceID, self.environment.desktopWorkspaceID)
                        .environment(\.chatAttachmentSession, self.environment.chatAttachmentSession)
                        .environment(\.chatProjectPath, self.environment.chatProjectPath)
                        .environment(\.openURL, OpenURLAction { [weak self] url in
                            guard let self else { return .discarded }
                            // Read the current route context even when a cached cell is reused.
                            self.environment.openURL(url)
                            return .handled
                        })
                        .frame(maxWidth: ChatContentStyle.columnWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .fixedSize(horizontal: false, vertical: true)
                        // The table owns bar/keyboard insets. A recycled cell passing underneath a
                        // bar must not shift its own SwiftUI text to avoid that same safe area again.
                        .ignoresSafeArea()
                        // Reusing a cell must never reuse another tool's disclosure state.
                        .id(id)
                }
                .margins(.horizontal, ChatContentStyle.horizontalInset)
                .margins(.vertical, ChatContentStyle.partSpacing / 2)
                .minSize(height: 0)
                return cell
            }
            table.onLayout = { [weak self] in self?.didLayout() }
        }

        func disconnect() {
            pagingTask?.cancel() // Only cancels this view's waiter, not the cached model's page.
            pagingTask = nil
            olderIndicator.stopAnimating()
            parent = nil
            table = nil
        }

        func update(_ parent: ChatTranscriptTable, environment: EnvironmentValues) {
            guard let table else { return }
            self.parent = parent
            keyboardDismissTap.isEnabled = parent.onDismissKeyboard != nil
            let environmentChanged = self.environment.stores !== environment.stores
                || self.environment.desktopWorkspaceID != environment.desktopWorkspaceID
                || self.environment.chatAttachmentSession !== environment.chatAttachmentSession
                || self.environment.chatProjectPath != environment.chatProjectPath
            self.environment = environment
            let restore = restorationRevision != parent.restorationRevision
            let jump = jumpRevision != parent.jumpRevision
            let revealLatest = latestRequestRevision != parent.latestRequestRevision
            if revealLatest {
                manualScroll = false
                jumping = false
                table.setContentOffset(table.contentOffset, animated: false)
            }
            // A late history/snapshot response must not pull someone away after they started
            // reading. Only an explicit navigation/send/jump intent resumes following output.
            if revealLatest || jump || (!wasRunning && parent.isRunning && !parent.isRestoring) {
                setFollowing(true)
            }
            restorationRevision = parent.restorationRevision
            jumpRevision = parent.jumpRevision
            latestRequestRevision = parent.latestRequestRevision
            wasRunning = parent.isRunning

            if !revealLatest, expansion != parent.expansion, let id = parent.expansion?.rowID,
               let path = dataSource.indexPath(for: id) {
                setFollowing(false)
                disclosureAnchor = Anchor(id: id, offset: table.rectForRow(at: path).minY
                    - table.contentOffset.y - table.adjustedContentInset.top)
            }
            expansion = parent.expansion

            let previous = rowsByID
            let ids = parent.rows.map(\.id)
            if let disclosureAnchor, !ids.contains(disclosureAnchor.id) { self.disclosureAnchor = nil }
            let structureChanged = rows.map(\.id) != ids
            // Reserve the small paging area while older history exists. Starting
            // its spinner then changes no row heights or scroll offsets.
            let wantsHeader = parent.onLoadOlder != nil || parent.loadingOlder
            let headerChanged = (table.tableHeaderView != nil) != wantsHeader
            let anchor = disclosureAnchor ?? (!followsOutput && (structureChanged || headerChanged) ? visibleAnchor() : nil)
            let preservingDisclosure = disclosureAnchor != nil
            let changed = parent.rows.compactMap { row -> Row.ID? in
                guard let old = previous[row.id], old != row || environmentChanged else { return nil }
                return row.id
            }
            rows = parent.rows
            rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

            if wantsHeader {
                olderHeader.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: 44)
                olderIndicator.center = CGPoint(x: table.bounds.width / 2, y: 22)
            }
            olderHeader.accessibilityElementsHidden = !parent.loadingOlder
            olderIndicator.isAccessibilityElement = parent.loadingOlder
            if parent.loadingOlder {
                if olderIndicator.superview == nil { olderHeader.addSubview(olderIndicator) }
                olderHeader.accessibilityElements = [olderIndicator]
                olderIndicator.startAnimating()
            } else {
                olderIndicator.stopAnimating()
                olderIndicator.removeFromSuperview()
                olderHeader.accessibilityElements = []
            }
            if headerChanged { table.tableHeaderView = wantsHeader ? olderHeader : nil }

            if structureChanged || !changed.isEmpty {
                measuredHeights = measuredHeights.filter { rowsByID[$0.key] != nil }
                var snapshot = NSDiffableDataSourceSnapshot<Int, Row.ID>()
                snapshot.appendSections([0])
                snapshot.appendItems(ids)
                snapshot.reconfigureItems(changed)
                updating = true
                snapshotRevision += 1
                let revision = snapshotRevision
                // A stream delta updates its cell in place. No insert/height animation per token,
                // and no reload of all the completed markdown and diff views above it.
                dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                    guard let self, self.snapshotRevision == revision else { return }
                    self.updating = false
                    table.layoutIfNeeded()
                    if let anchor { self.restore(anchor) }
                    // A small disclosure (or collapse) can leave the whole tail in view.
                    // Do not offer Jump to Latest when the reader is already there.
                    if preservingDisclosure && self.isAtBottom(table) { self.setFollowing(true) }
                    self.pinLatest()
                    self.schedulePinLatest()
                }
            } else if headerChanged {
                table.layoutIfNeeded()
                if let anchor { self.restore(anchor) }
                pinLatest()
            } else if restore || revealLatest { pinLatest() }

            if jump, let last = rows.indices.last {
                let bottom = max(-table.adjustedContentInset.top,
                                 table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
                if abs(table.contentOffset.y - bottom) > 0.5 {
                    jumping = true
                    table.scrollToRow(at: IndexPath(row: last, section: 0), at: .bottom, animated: true)
                }
            }
        }

        @objc private func dismissKeyboard(_ recognizer: UITapGestureRecognizer) {
            // A field in safeAreaBar can own the keyboard without updating FocusState.
            // Target editable input in this window, preserving native message selection.
            ChatKeyboardDismissal.dismiss(in: table?.window, at: recognizer.location(in: table?.window)) {
                parent?.onDismissKeyboard?()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        private func visibleAnchor() -> Anchor? {
            guard let table else { return nil }
            let visibleTop = table.contentOffset.y + table.adjustedContentInset.top
            guard let path = table.indexPathsForVisibleRows?.sorted().first(where: {
                table.rectForRow(at: $0).maxY > visibleTop
            }),
                  let id = dataSource.itemIdentifier(for: path) else { return nil }
            return Anchor(id: id, offset: table.rectForRow(at: path).minY - visibleTop)
        }

        private func restore(_ anchor: Anchor) {
            guard !followsOutput, let table, let path = dataSource.indexPath(for: anchor.id) else { return }
            positioning = true
            defer { positioning = false }
            if table.indexPathsForVisibleRows?.contains(path) != true {
                table.scrollToRow(at: path, at: .top, animated: false)
                table.layoutIfNeeded()
            }
            let offset = table.rectForRow(at: path).minY - table.adjustedContentInset.top - anchor.offset
            if abs(table.contentOffset.y - offset) > 0.5 { table.contentOffset.y = offset }
        }

        private func didLayout() {
            guard !updating, !positioning else { return }
            // UIHostingConfiguration can settle its height on a later layout pass. Hold the
            // selected disclosure's position through those measurements until the reader moves.
            if let disclosureAnchor, !manualScroll { restore(disclosureAnchor) }
            pinLatest()
        }

        private func schedulePinLatest() {
            guard !pinScheduled, followsOutput else { return }
            pinScheduled = true
            // Hosting cells can finish measuring after the diffable completion.
            // Coalesce one settling pass; never keep a display timer running.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pinScheduled = false
                self.pinLatest()
            }
        }

        /// Realize the final cell before using contentSize. A distant estimated offset in a lazy
        /// SwiftUI stack could contain no painted views; a native row target is measured on arrival.
        private func pinLatest() {
            guard followsOutput, !manualScroll, !positioning, !updating, !jumping,
                  let table, table.bounds.height > 0, let last = rows.indices.last else { return }
            positioning = true
            defer { positioning = false }
            let path = IndexPath(row: last, section: 0)
            if table.indexPathsForVisibleRows?.contains(path) != true {
                table.scrollToRow(at: path, at: .bottom, animated: false)
                table.layoutIfNeeded()
            }
            // Moving to the tail can realize another estimated row and change
            // contentSize again. Settle that measurement before leaving the last
            // answer partially below the viewport.
            for _ in 0..<3 {
                table.layoutIfNeeded()
                let bottom = max(-table.adjustedContentInset.top,
                                 max(table.contentSize.height, table.rectForRow(at: path).maxY)
                                    - table.bounds.height + table.adjustedContentInset.bottom)
                guard abs(table.contentOffset.y - bottom) > 0.5 else { break }
                table.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            }
        }

        private func setFollowing(_ following: Bool) {
            if following { disclosureAnchor = nil }
            guard followsOutput != following else { return }
            followsOutput = following
            // Geometry callbacks can run during SwiftUI's update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent?.onFollowingChanged(self.followsOutput)
            }
        }

        private func isAtBottom(_ scroll: UIScrollView) -> Bool {
            scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom >= scroll.contentSize.height - 60
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            disclosureAnchor = nil
            manualScroll = true
            jumping = false
            setFollowing(false)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard manualScroll, !positioning, !updating else { return }
            setFollowing(isAtBottom(scrollView))
            guard scrollView.contentOffset.y + scrollView.adjustedContentInset.top < 80,
                  parent?.loadingOlder == false, pagingTask == nil, let load = parent?.onLoadOlder else { return }
            pagingTask = Task { [weak self] in
                await load()
                self?.pagingTask = nil
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { endManualScroll(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { endManualScroll(scrollView) }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            scrollViewWillBeginDragging(scrollView)
            return true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { endManualScroll(scrollView) }

        private func endManualScroll(_ scrollView: UIScrollView) {
            manualScroll = false
            setFollowing(isAtBottom(scrollView))
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            jumping = false
            pinLatest()
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return 100 }
            return measuredHeights[id] ?? 100
        }

        func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            // The index path may already refer to another row after an older page was prepended.
            guard let id = (cell as? TranscriptCell)?.rowID?.base as? Row.ID, rowsByID[id] != nil else { return }
            measuredHeights[id] = cell.bounds.height
        }
    }
}

private final class TranscriptCell: UITableViewCell {
    var rowID: AnyHashable?
}

private final class TranscriptTableView: UITableView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
