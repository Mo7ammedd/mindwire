import SwiftUI
import UIKit

/// Only the small section heading observes this state. Scrolling never invalidates the
/// repository screen, rebuilds the Git tree, or starts a workspace request.
@MainActor @Observable
final class GitBreadcrumbState {
    private(set) var context: GitBreadcrumbContext?
    var path: String { context?.folder ?? "" }

    func update(_ context: GitBreadcrumbContext?) {
        if self.context != context { self.context = context }
    }
}

struct GitBreadcrumbContext: Equatable {
    let scope: String
    let folder: String
}

struct GitBreadcrumbRow {
    let scope: String
    let folder: String
    let frame: CGRect
    var header = false

    static func folder(path: String, directory: Bool) -> String {
        directory ? path : (path as NSString).deletingLastPathComponent
    }
}

/// The native safe area defines the reading edge. Inspect only visible cells,
/// including unmarked overview rows so the context clears on returning to the top.
enum GitBreadcrumbPosition {
    static func row(top: CGFloat, bottom: CGFloat, rows: [GitBreadcrumbRow]) -> GitBreadcrumbRow? {
        rows.lazy.filter { $0.frame.maxY > top + 1 && $0.frame.minY < bottom }
            .min { $0.frame.minY < $1.frame.minY }
    }

    static func context(for row: GitBreadcrumbRow?) -> GitBreadcrumbContext? {
        guard let row, !row.scope.isEmpty, !row.header else { return nil }
        return GitBreadcrumbContext(scope: row.scope, folder: row.folder)
    }

    static func context(top: CGFloat, bottom: CGFloat, rows: [GitBreadcrumbRow]) -> GitBreadcrumbContext? {
        context(for: row(top: top, bottom: bottom, rows: rows))
    }
}

struct GitChangeSectionInfo {
    let scope: String
    let title: String
    let count: Int
    let staged: Bool
    let bulkAction: Bool
}

/// One permanent native bar joins the folder context to the navigation area. Its
/// height never depends on scrolling: only the contents change at folder boundaries.
struct GitRepositoryContextBar: View {
    let model: GitModel
    let breadcrumb: GitBreadcrumbState
    let sections: [GitChangeSectionInfo]
    @Binding var expanded: Bool
    let showActions: Bool
    let chooseBranch: () -> Void
    let showHistory: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 44

    var body: some View {
        Group {
            if let context = breadcrumb.context,
               let section = sections.first(where: { $0.scope == context.scope && $0.count > 0 }) {
                GitChangeSectionControls(model: model, section: section, expanded: $expanded,
                                         showActions: showActions, breadcrumb: breadcrumb)
            } else {
                GitRepositorySummary(model: model, chooseBranch: chooseBranch, showHistory: showHistory)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.xs)
        .background(Color(.systemBackground))
        .transaction { $0.animation = nil }
    }
}

/// The same section actions are shared by its inline row and the native context bar.
struct GitChangeSectionControls: View {
    let model: GitModel
    let section: GitChangeSectionInfo
    @Binding var expanded: Bool
    let showActions: Bool
    var breadcrumb: GitBreadcrumbState? = nil

    var body: some View {
        GitChangeSectionHeader(title: section.title, count: section.count,
            expanded: section.staged && showActions ? expanded : nil,
            onToggle: { withAnimation(.snappy) { expanded.toggle() } },
            scope: section.scope, breadcrumb: breadcrumb) {
            if section.bulkAction && showActions {
                Button(t(section.staged ? "git.unstageAll" : "git.stageAll")) {
                    Task { if section.staged { await model.unstageAll() } else { await model.stageAll() } }
                }
                .textCase(nil).tint(.primary).disabled(model.isMutating)
            }
        }
    }
}

struct GitChangeSectionHeader<Actions: View>: View {
    let title: String
    let count: Int
    var expanded: Bool? = nil
    var onToggle: (() -> Void)? = nil
    let scope: String
    var breadcrumb: GitBreadcrumbState? = nil
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let path = breadcrumb?.context?.scope == scope ? breadcrumb?.path ?? "" : ""
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.sm) {
                if let expanded, let onToggle {
                    Button(action: onToggle) { heading }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t(expanded ? "git.staged.collapse" : "git.staged.expand"))
                        .accessibilityValue(t("git.stagedCount", ["count": "\(count)"]))
                        .accessibilityIdentifier("git.toggleStaged")
                } else { heading }
                Spacer(minLength: 0)
                actions().fixedSize(horizontal: true, vertical: false)
            }
            .font(path.isEmpty ? .subheadline : .caption)
            if !path.isEmpty {
                GitFolderBreadcrumb(path: path, scope: scope)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
        .transaction { $0.animation = nil }
    }

    private var heading: some View {
        HStack(spacing: Spacing.xs) {
            Text(title).lineLimit(1)
            Text(count.formatted()).foregroundStyle(.secondary)
            if let expanded {
                AppIcon(expanded ? .chevronDown : .chevronRight)
                    .font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
        }
        .foregroundStyle(Color.secondary)
        .contentShape(.rect)
    }
}

private struct GitFolderBreadcrumb: View {
    let path: String
    let scope: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(styledPath)
                .font(.subheadline)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(t("git.currentFolder"))
                .accessibilityValue(path)
                .accessibilityIdentifier("git.breadcrumb.\(scope)")
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .defaultScrollAnchor(.trailing, for: .initialOffset)
        .defaultScrollAnchor(.leading, for: .alignment)
        .accessibilityIdentifier("git.breadcrumb.scroll.\(scope)")
        // Only the horizontal path resets. No scrollTo call can reach the outer List.
        .id(path)
    }

    private var styledPath: AttributedString {
        var result = AttributedString()
        for (index, component) in path.split(separator: "/").enumerated() {
            if index > 0 {
                var separator = AttributedString(" › ")
                separator.foregroundColor = Color.primary.opacity(0.35)
                result.append(separator)
            }
            var folder = AttributedString(String(component))
            folder.foregroundColor = .primary
            result.append(folder)
        }
        return result
    }
}

/// One observer per native List. Weak markers associate recycled cells with their paths.
/// Samples coalesce on the main run loop and inspect only UICollectionView.visibleCells.
@MainActor
final class GitScrollBreadcrumb {
    let current = GitBreadcrumbState()
    private weak var collection: UICollectionView?
    private var observations: [NSKeyValueObservation] = []
    private let cells = NSMapTable<UICollectionViewCell, GitBreadcrumbMarkerView>.weakToWeakObjects()
    private var scheduled = false
    private var readingRange: Range<CGFloat>?
#if DEBUG
    private var treeBodies = 0
    private var treeBuilds = 0
    private var scans = 0
    private var rowBodies = 0
    private var maximumVisibleCells = 0
    private var scanNanoseconds: UInt64 = 0
    private var frames: GitScrollFrameMetrics?
    func recordTreeBody() { treeBodies += 1 }
    func recordTreeBuild() { treeBuilds += 1 }
    func recordRowBody() { rowBodies += 1 }
    fileprivate func measureFrames() { if frames == nil { frames = GitScrollFrameMetrics() } }
    fileprivate var metrics: String {
        "bodies=\(treeBodies);builds=\(treeBuilds);rows=\(rowBodies);scans=\(scans);visible=\(maximumVisibleCells);meanMicros=\(scans == 0 ? 0 : scanNanoseconds / UInt64(scans) / 1_000);offset=\(Int(collection?.contentOffset.y ?? 0));inset=\(Int(collection?.adjustedContentInset.top ?? 0));\(frames?.metrics ?? "")"
    }
#endif

    fileprivate func attach(_ marker: GitBreadcrumbMarkerView, collection: UICollectionView,
                            host: UICollectionReusableView) {
        if self.collection !== collection {
            observations.forEach { $0.invalidate() }
            cells.removeAllObjects()
            self.collection = collection
            observations = [
                collection.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                },
                collection.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                    guard change.oldValue != change.newValue else { return }
                    MainActor.assumeIsolated { self?.invalidate() }
                }
            ]
        }
        if let cell = host as? UICollectionViewCell, cells.object(forKey: cell) !== marker {
            cells.setObject(marker, forKey: cell)
            invalidate()
        }
    }

    fileprivate func detach(_ marker: GitBreadcrumbMarkerView) {
        if let cell = marker.host as? UICollectionViewCell, cells.object(forKey: cell) === marker {
            cells.removeObject(forKey: cell)
            invalidate()
        }
    }

    fileprivate func invalidate() {
        readingRange = nil
        schedule()
    }

    private func scrolled() {
        guard let collection else { return }
#if DEBUG
        frames?.observe(collection)
#endif
        let top = collection.contentOffset.y + collection.adjustedContentInset.top
        // Most scroll frames remain inside the same row, especially a tall Review preview.
        if readingRange?.contains(top) == true { return }
        schedule()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.sample()
        }
    }

    private func sample() {
#if DEBUG
        let start = DispatchTime.now().uptimeNanoseconds
        defer { scans += 1; scanNanoseconds += DispatchTime.now().uptimeNanoseconds - start }
#endif
        guard let collection, collection.window != nil else {
            readingRange = nil
            current.update(nil)
            return
        }
        let top = collection.contentOffset.y + collection.adjustedContentInset.top
        let bottom = collection.contentOffset.y + collection.bounds.height - collection.adjustedContentInset.bottom
        let visibleCells = collection.visibleCells
#if DEBUG
        maximumVisibleCells = max(maximumVisibleCells, visibleCells.count)
#endif
        let rows = visibleCells.map { cell -> GitBreadcrumbRow in
            let frame = cell.convert(cell.bounds, to: collection)
            guard let marker = cells.object(forKey: cell), marker.host === cell, marker.window != nil else {
                return GitBreadcrumbRow(scope: "", folder: "", frame: frame)
            }
            return GitBreadcrumbRow(scope: marker.scope, folder: marker.folder,
                                    frame: frame, header: marker.header)
        }
        let row = GitBreadcrumbPosition.row(top: top, bottom: bottom, rows: rows)
        if let row, row.frame.maxY - 1 > min(top, row.frame.minY) {
            readingRange = min(top, row.frame.minY)..<(row.frame.maxY - 1)
        } else { readingRange = nil }
        current.update(GitBreadcrumbPosition.context(for: row))
    }

}

struct GitBreadcrumbMarker: UIViewRepresentable {
    let tracker: GitScrollBreadcrumb
    let scope: String
    var path = ""
    var directory = false
    var header = false

    func makeUIView(context: Context) -> GitBreadcrumbMarkerView { GitBreadcrumbMarkerView(frame: .zero) }

    func updateUIView(_ view: GitBreadcrumbMarkerView, context: Context) {
        let folder = GitBreadcrumbRow.folder(path: path, directory: directory)
        let ownerChanged = view.tracker !== tracker
        let changed = ownerChanged || view.scope != scope || view.header != header || view.folder != folder
        if ownerChanged {
            view.tracker?.detach(view)
            view.host = nil
        }
        view.tracker = tracker
        view.scope = scope
        view.folder = folder
        view.header = header
        if view.host == nil { view.resolve() }
        if changed { tracker.invalidate() }
    }

    static func dismantleUIView(_ view: GitBreadcrumbMarkerView, coordinator: ()) {
        view.tracker?.detach(view)
        view.tracker = nil
    }
}

final class GitBreadcrumbMarkerView: UIView {
    weak var tracker: GitScrollBreadcrumb?
    weak var host: UICollectionReusableView?
    var scope = ""
    var folder = ""
    var header = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { tracker?.detach(self); host = nil }
        else { resolve() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let host, isDescendant(of: host) { return }
        resolve()
    }

    func resolve() {
        guard window != nil else { return }
        var ancestor = superview
        var host: UICollectionReusableView?
        while let view = ancestor {
            if host == nil { host = view as? UICollectionReusableView }
            if let collection = view as? UICollectionView, let host {
                // SwiftUI can move a row between recycled cells during a section update.
                if self.host !== host { tracker?.detach(self) }
                self.host = host
                tracker?.attach(self, collection: collection, host: host)
                return
            }
            ancestor = view.superview
        }
    }
}

#if DEBUG
/// An on-demand counter read for the isolated scroll fixture, with no published state.
struct GitScrollMetricsProbe: UIViewRepresentable {
    let tracker: GitScrollBreadcrumb
    func makeUIView(context: Context) -> GitScrollMetricsView { GitScrollMetricsView(frame: .zero) }
    func updateUIView(_ view: GitScrollMetricsView, context: Context) {
        view.tracker = tracker
        tracker.measureFrames()
    }
}

/// Fixture-only display timing. Runs during an actual drag/deceleration and stops
/// when it ends; normal app sessions never create this sampler or a display link.
@MainActor private final class GitScrollFrameMetrics: NSObject {
    private weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var samples = 0
    private var slowFrames = 0
    private var maximumInterval: CFTimeInterval = 0
    private var firstDrag = true
    private var firstDragSamples = 0
    private var firstDragMaximum: CFTimeInterval = 0

    var metrics: String {
        "frameSamples=\(samples);framesOver50ms=\(slowFrames);maxFrameMicros=\(Int(maximumInterval * 1_000_000));firstDragSamples=\(firstDragSamples);firstDragMaxMicros=\(Int(firstDragMaximum * 1_000_000))"
    }

    func observe(_ scrollView: UIScrollView) {
        guard link == nil, scrollView.isDragging || scrollView.isDecelerating else { return }
        self.scrollView = scrollView
        previousTimestamp = nil
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView, scrollView.window != nil,
              scrollView.isDragging || scrollView.isDecelerating else {
            link.invalidate()
            self.link = nil
            previousTimestamp = nil
            if firstDragSamples > 0 { firstDrag = false }
            return
        }
        if let previousTimestamp {
            let interval = link.timestamp - previousTimestamp
            samples += 1
            maximumInterval = max(maximumInterval, interval)
            if interval > 0.05 { slowFrames += 1 }
            if firstDrag {
                firstDragSamples += 1
                firstDragMaximum = max(firstDragMaximum, interval)
            }
        }
        previousTimestamp = link.timestamp
    }
}

final class GitScrollMetricsView: UIView {
    weak var tracker: GitScrollBreadcrumb?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        isUserInteractionEnabled = false
        accessibilityIdentifier = "git.scroll.metrics"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var accessibilityValue: String? {
        get { tracker?.metrics }
        set { }
    }
}
#endif
