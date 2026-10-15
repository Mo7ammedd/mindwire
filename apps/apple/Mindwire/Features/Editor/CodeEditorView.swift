import Runestone
import SwiftUI

/// How a line present in the current file changed vs HEAD, for the editor's VS Code-style gutter bars.
enum GutterKind: Hashable { case added, modified }

/// Full-line diff highlight kind for the *diff-in-editor* view (Source Control open): the buffer holds
/// the reconstructed inline diff, and these tint whole lines — green added, red removed.
enum DiffTint: Hashable { case added, removed }

/// Per-line git change info for the editor gutter: which current-file lines are added/modified, plus
/// the line numbers that sit just below a pure deletion (a small red caret is drawn there).
struct EditorChanges: Equatable {
    var lineKinds: [Int: GutterKind] = [:]   // 1-based current-file line → added / modified
    var deletionAnchors: Set<Int> = []       // 1-based current-file line with removed line(s) above it
    var isEmpty: Bool { lineKinds.isEmpty && deletionAnchors.isEmpty }
}

/// Holds a weak reference to the live Runestone `TextView` so the screen can insert symbols at the
/// caret and read the current selection (e.g. for "Send to Agent").
final class EditorHandle: ObservableObject {
    weak var textView: TextView?
    func insert(_ string: String) { textView?.insertText(string) }

    /// The currently selected text, or nil when nothing is selected.
    var selectedText: String? {
        guard let tv = textView, tv.selectedRange.length > 0 else { return nil }
        return tv.text(in: tv.selectedRange)
    }
}

/// Transparent overlay that paints thin VS Code-style change bars in the gutter margin. Positioned in
/// the scroll view's CONTENT coordinates so it scrolls with the text; drawn behind nothing it cares
/// about (the gutter background is clear). Not interactive.
final class GutterBarView: UIView {
    struct Bar { let y: CGFloat; let height: CGFloat; let kind: GutterKind }
    var bars: [Bar] = []
    var deletionYs: [CGFloat] = []
    var addedColor: UIColor = .systemGreen
    var modifiedColor: UIColor = .systemBlue
    var removedColor: UIColor = .systemRed
    private let barWidth: CGFloat = 1.5   // thin hairline, VS Code-style
    private let trailingGap: CGFloat = 5  // space between the bar and the code (not hugging line start)

    /// Bar x-origin: sits in the gutter's trailing padding, a few px left of where the code begins.
    private var barX: CGFloat { max(0, bounds.width - barWidth - trailingGap) }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let x = barX
        for bar in bars {
            ctx.setFillColor((bar.kind == .added ? addedColor : modifiedColor).cgColor)
            let r = CGRect(x: x, y: bar.y, width: barWidth, height: bar.height)
            ctx.addPath(UIBezierPath(roundedRect: r, cornerRadius: barWidth / 2).cgPath)
            ctx.fillPath()
        }
        // Deletion caret: a small triangle pointing down at the gap where lines were removed.
        ctx.setFillColor(removedColor.cgColor)
        let s: CGFloat = 6
        for y in deletionYs {
            let cx = x + barWidth / 2
            let p = UIBezierPath()
            p.move(to: CGPoint(x: cx - s / 2, y: y - s / 2))
            p.addLine(to: CGPoint(x: cx + s / 2, y: y - s / 2))
            p.addLine(to: CGPoint(x: cx, y: y + s / 2))
            p.close()
            ctx.addPath(p.cgPath)
            ctx.fillPath()
        }
    }
}

/// An opaque sign and a thin rail distinguish changes without washing out the code. The view is
/// only as tall as the viewport; wrapped lines keep one sign and a rail across all their fragments.
final class DiffLineMarkerView: UIView {
    struct Marker: Equatable {
        let y: CGFloat
        let height: CGFloat
        let firstLineHeight: CGFloat
        let tint: DiffTint
    }
    var markers: [Marker] = [] {
        didSet { if markers != oldValue { setNeedsDisplay() } }
    }
    var font = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold) {
        didSet { if font != oldValue { setNeedsDisplay() } }
    }
    var addedColor: UIColor = .label
    var removedColor: UIColor = .label

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for marker in markers {
            let color = marker.tint == .added ? addedColor : removedColor
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: bounds.width - 4, y: marker.y, width: 2, height: marker.height))
            let sign = (marker.tint == .added ? "+" : "−") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = sign.size(withAttributes: attributes)
            sign.draw(at: CGPoint(x: bounds.width - size.width - 8,
                                  y: marker.y + (marker.firstLineHeight - size.height) / 2),
                      withAttributes: attributes)
        }
    }
}

/// Runestone `TextView` with file change bars and explicit diff markers. Public caret/line APIs
/// provide the geometry; decorations stay below native scroll-edge effects.
final class DiffGutterTextView: TextView {
    var pendingRevealLine: Int?
    private let barView = GutterBarView()
    private let diffMarkerView = DiffLineMarkerView()
    private let gutterBackdrop = UIView()
    private var barsDirty = true

    var editorChanges = EditorChanges() {
        didSet { if editorChanges != oldValue { barsDirty = true; setNeedsLayout() } }
    }
    var diffTints: [Int: DiffTint] = [:] {
        didSet { if diffTints != oldValue { setNeedsLayout() } }
    }
    /// Hidden while editing (line numbers shift, so the diff map no longer matches).
    var showBars = true {
        didSet { if showBars != oldValue { barView.isHidden = !showBars; barsDirty = true; setNeedsLayout() } }
    }

    override init(frame: CGRect) { super.init(frame: frame); setUpBars() }
    required init?(coder: NSCoder) { super.init(coder: coder); setUpBars() }

    private func setUpBars() {
        barView.isUserInteractionEnabled = false
        barView.backgroundColor = .clear
        barView.contentMode = .redraw
        addSubview(barView)
        diffMarkerView.isUserInteractionEnabled = false
        diffMarkerView.isAccessibilityElement = false
        diffMarkerView.isOpaque = false
        diffMarkerView.backgroundColor = .clear
        diffMarkerView.contentMode = .redraw
        addSubview(diffMarkerView)
        gutterBackdrop.isUserInteractionEnabled = false
        gutterBackdrop.isAccessibilityElement = false
        gutterBackdrop.isOpaque = true
        gutterBackdrop.accessibilityIdentifier = "editor.gutter.backdrop"
        gutterBackdrop.isHidden = true
        addSubview(gutterBackdrop)
    }

    func setBarColors(dark: Bool) {
        let c = EditorTheme.gutterColors(dark: dark)
        barView.addedColor = c.added; barView.modifiedColor = c.modified; barView.removedColor = c.removed
        barView.setNeedsDisplay()
        diffMarkerView.addedColor = c.added
        diffMarkerView.removedColor = c.removed
        diffMarkerView.setNeedsDisplay()
    }

    /// Force a geometry recompute (e.g. after a font-size change alters line height).
    func markBarsDirty() { barsDirty = true; setNeedsLayout() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = CGRect(x: bounds.minX, y: 0, width: gutterWidth, height: max(contentSize.height, bounds.height))
        if barView.bounds.size != frame.size { barsDirty = true }
        if barView.frame != frame { barView.frame = frame }
        if barsDirty, showBars, let geo = computeGeometry() {
            barView.bars = geo.bars
            barView.deletionYs = geo.deletionYs
            barView.setNeedsDisplay()
            barsDirty = false
        }
        layoutGutterBackdrop()
        layoutDiffMarkers()
        layoutGutterBelowScrollEdges()
        if let line = pendingRevealLine, bounds.height > 0, bounds.width > 0 {
            pendingRevealLine = nil
            if let offset = location(at: TextLocation(lineNumber: max(0, line - 1), column: 0)) {
                scrollRangeToVisible(NSRange(location: offset, length: 0))
            }
        }
    }

    private func layoutGutterBackdrop() {
        // Match the editor surface exactly, with a hard edge that stops at the pinned column.
        // Transparent editors use the native page/sheet background, including its elevation traits.
        gutterBackdrop.isHidden = !showLineNumbers || gutterWidth <= 0
            || contentOffset.x + adjustedContentInset.left <= 0.5
        guard !gutterBackdrop.isHidden else { return }
        if let backgroundColor, backgroundColor.resolvedColor(with: traitCollection).cgColor.alpha == 1 {
            gutterBackdrop.backgroundColor = backgroundColor
        } else {
            gutterBackdrop.backgroundColor = .systemBackground
        }
        gutterBackdrop.frame = CGRect(x: bounds.minX, y: bounds.minY,
                                      width: gutterWidth, height: bounds.height)
    }

    private func layoutDiffMarkers() {
        diffMarkerView.isHidden = diffTints.isEmpty
        guard !diffTints.isEmpty, gutterWidth > 0 else { return }
        // Pin to the gutter horizontally, while drawing with native content Y coordinates.
        diffMarkerView.frame = CGRect(x: bounds.minX, y: bounds.minY,
                                      width: gutterWidth, height: bounds.height)
        diffMarkerView.font = .monospacedSystemFont(ofSize: theme.font.pointSize, weight: .semibold)

        func line(at y: CGFloat) -> Int? {
            guard let position = closestPosition(to: CGPoint(x: gutterWidth, y: max(0, y))) else { return nil }
            return textLocation(at: offset(from: beginningOfDocument, to: position))?.lineNumber
        }
        guard let first = line(at: bounds.minY), let last = line(at: bounds.maxY), first <= last else {
            diffMarkerView.markers = []
            return
        }
        var markers: [DiffLineMarkerView.Marker] = []
        for line in first...last {
            guard let tint = diffTints[line + 1],
                  let offset = location(at: TextLocation(lineNumber: line, column: 0)),
                  let start = position(from: beginningOfDocument, offset: offset) else { continue }
            let firstRect = caretRect(for: start)
            guard firstRect.height > 0, firstRect.minY.isFinite else { continue }
            let bottom: CGFloat
            if let nextOffset = location(at: TextLocation(lineNumber: line + 1, column: 0)),
               let next = position(from: beginningOfDocument, offset: nextOffset) {
                bottom = caretRect(for: next).minY
            } else {
                bottom = caretRect(for: endOfDocument).maxY
            }
            markers.append(.init(y: firstRect.minY - bounds.minY,
                                 height: max(firstRect.height, bottom - firstRect.minY),
                                 firstLineHeight: firstRect.height, tint: tint))
        }
        diffMarkerView.markers = markers
    }

    private func layoutGutterBelowScrollEdges() {
        // Runestone raises its gutter above every sibling on each layout. Keep editor decorations
        // directly above the UITextInput canvas, leaving the system's scroll-edge effects above
        // all code and line numbers. Identify editor content by public protocol/geometry only.
        guard let canvas = subviews.first(where: { $0 is UITextInput }) else { return }
        let gutter = subviews.first {
            $0 !== canvas && $0 !== barView && $0 !== diffMarkerView && $0 !== gutterBackdrop
                && type(of: $0) == UIView.self
                && gutterWidth > 0 && abs($0.bounds.width - gutterWidth) < 0.5
        }
        insertSubview(gutterBackdrop, aboveSubview: canvas)
        if let gutter { insertSubview(gutter, aboveSubview: gutterBackdrop) }
        insertSubview(barView, aboveSubview: gutter ?? gutterBackdrop)
        insertSubview(diffMarkerView, aboveSubview: barView)
    }

    /// (bars, deletionYs) in content coordinates, or nil if the layout isn't ready yet (retry later).
    private func computeGeometry() -> (bars: [GutterBarView.Bar], deletionYs: [CGFloat])? {
        if editorChanges.isEmpty { return ([], []) }
        let firstRect = caretRect(for: beginningOfDocument)
        guard firstRect.height.isFinite, firstRect.height > 0 else { return nil }
        let origin = firstRect.minY
        var lineHeight = firstRect.height
        // Prefer the exact line pitch (caret Δ between line 1 and line 2), so bars stay contiguous.
        let ns = text as NSString
        let firstNL = ns.range(of: "\n")
        if firstNL.location != NSNotFound, let p2 = position(from: beginningOfDocument, offset: firstNL.location + 1) {
            let delta = caretRect(for: p2).minY - origin
            if delta > 1 { lineHeight = delta }
        }
        func y(_ line: Int) -> CGFloat { origin + CGFloat(line - 1) * lineHeight }

        // Coalesce consecutive same-kind lines into a single bar (VS Code shows one bar per block).
        var bars: [GutterBarView.Bar] = []
        let sorted = editorChanges.lineKinds.sorted { $0.key < $1.key }
        var i = 0
        while i < sorted.count {
            let (start, kind) = sorted[i]
            var end = start, j = i + 1
            while j < sorted.count, sorted[j].key == end + 1, sorted[j].value == kind { end = sorted[j].key; j += 1 }
            bars.append(.init(y: y(start), height: CGFloat(end - start + 1) * lineHeight, kind: kind))
            i = j
        }
        let deletionYs = editorChanges.deletionAnchors.map { y($0) }
        return (bars, deletionYs)
    }
}

/// SwiftUI wrapper around Runestone's `TextView` — native selection, caret, and the iOS edit menu,
/// with tree-sitter syntax highlighting, line numbers, and VS Code-style git gutter bars. Read-only
/// unless `isEditable`. Font size + line wrapping come from app-wide editor settings.
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    var language: TreeSitterLanguage?
    var fontSize: CGFloat
    var isDark: Bool
    var wrapLines: Bool
    var isEditable: Bool
    /// Git change info driving the gutter bars (file mode). Hidden while editing (line numbers shift).
    var changes: EditorChanges = EditorChanges()
    /// Full-line red/green backgrounds for the diff-in-editor view (Source Control). Keyed by 1-based
    /// buffer line. The reconstructed diff uses explicit +/- gutter markers instead of file bars.
    var diffTints: [Int: DiffTint] = [:]
    /// A review/navigation highlight, independent of the user's native text selection.
    var focusedRange: NSRange? = nil
    /// The SwiftUI viewport's bar/keyboard insets when the editor extends beneath native bars.
    /// Nil preserves automatic UIKit inset handling for editors contained inside the safe area.
    var contentSafeAreaInsets: EdgeInsets? = nil
    /// Called with the current selection (nil when empty) — drives the "Send to Agent" quick action.
    var onSelectionChange: ((String?) -> Void)? = nil
    var handle: EditorHandle?
    var initialLine: Int? = nil

    private func theme() -> EditorTheme { isDark ? .onvo(fontSize: fontSize) : .light(fontSize: fontSize) }

    func makeUIView(context: Context) -> DiffGutterTextView {
        let textView = DiffGutterTextView(frame: .zero)
        textView.editorDelegate = context.coordinator
        textView.showLineNumbers = true
        textView.gutterLeadingPadding = 8
        textView.gutterTrailingPadding = diffTints.isEmpty ? 14 : max(22, fontSize + 8)
        textView.isLineWrappingEnabled = wrapLines   // off ⇒ long lines scroll horizontally
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.topEdgeEffect.style = .soft
        textView.bottomEdgeEffect.style = .soft
        // Code, not prose — disable all the "smart" text transforms.
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        let theme = theme()
        textView.backgroundColor = .clear   // transparent → the modal's native surface shows through
        textView.tintColor = theme.caretColor
        // `language:` is non-optional — use the plain-text state when we have no grammar.
        if let language {
            textView.setState(TextViewState(text: text, theme: theme, language: language))
        } else {
            textView.setState(TextViewState(text: text, theme: theme))
        }
        context.coordinator.appliedFontSize = fontSize
        context.coordinator.appliedDark = isDark
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.lastTextLength = (text as NSString).length
        textView.setBarColors(dark: isDark)
        textView.showBars = !isEditable && diffTints.isEmpty
        textView.editorChanges = changes
        applyDiffTints(to: textView, context: context, force: true)
        applyViewportInsets(to: textView)
        handle?.textView = textView
        textView.pendingRevealLine = initialLine
        return textView
    }

    func updateUIView(_ textView: DiffGutterTextView, context: Context) {
        context.coordinator.text = $text
        let textChanged = textView.text != text
        if textChanged { textView.text = text }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        if textView.isLineWrappingEnabled != wrapLines { textView.isLineWrappingEnabled = wrapLines }
        // Re-apply the theme only when size/appearance actually changed (not on every keystroke).
        var themeChanged = false
        if context.coordinator.appliedFontSize != fontSize || context.coordinator.appliedDark != isDark {
            let theme = theme()
            textView.theme = theme
            textView.backgroundColor = .clear
            textView.tintColor = theme.caretColor
            textView.setBarColors(dark: isDark)
            textView.markBarsDirty()   // font size may have changed line height
            context.coordinator.appliedFontSize = fontSize
            context.coordinator.appliedDark = isDark
            themeChanged = true
        }
        textView.showBars = !isEditable && diffTints.isEmpty
        textView.gutterTrailingPadding = diffTints.isEmpty ? 14 : max(22, fontSize + 8)
        if textView.editorChanges != changes { textView.editorChanges = changes }
        applyDiffTints(to: textView, context: context, force: themeChanged || textChanged)
        applyViewportInsets(to: textView)
        context.coordinator.onSelectionChange = onSelectionChange
    }

    private func applyViewportInsets(to textView: DiffGutterTextView) {
        guard let safeArea = contentSafeAreaInsets else { return }
        textView.contentInsetAdjustmentBehavior = .never
        textView.automaticallyAdjustsScrollIndicatorInsets = false
        textView.alwaysBounceVertical = true
        let insets = UIEdgeInsets(top: safeArea.top + Spacing.sm, left: 0,
                                 bottom: safeArea.bottom + Spacing.sm, right: 0)
        if textView.contentInset != insets {
            // Keep the same line at the visible top when a bar or the viewport changes size. This
            // also places line one below the header on the first layout, without moving selection.
            let offset = textView.contentOffset.y + textView.contentInset.top - insets.top
            textView.contentInset = insets
            let maximum = max(-insets.top, textView.contentSize.height - textView.bounds.height + insets.bottom)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x,
                                              y: min(max(offset, -insets.top), maximum)), animated: false)
        }
        textView.verticalScrollIndicatorInsets = UIEdgeInsets(top: safeArea.top, left: 0,
                                                             bottom: safeArea.bottom, right: 0)
    }

    /// Runestone draws review focus over the existing diff tints. Keep the diff ranges cached when
    /// moving between changes, and never turn navigation into a native text selection.
    private func applyDiffTints(to textView: DiffGutterTextView, context: Context, force: Bool) {
        let coordinator = context.coordinator
        let diffChanged = force || coordinator.appliedDiffTints != diffTints
        guard diffChanged || coordinator.appliedFocusedRange != focusedRange else { return }
        if diffChanged {
            coordinator.appliedDiffTints = diffTints
            textView.diffTints = diffTints
            coordinator.diffRanges = Self.diffHighlightRanges(for: text, tints: diffTints, dark: isDark)
        }
        coordinator.appliedFocusedRange = focusedRange
        var ranges = coordinator.diffRanges
        if let focusedRange, focusedRange.location != NSNotFound, focusedRange.length > 0,
           focusedRange.location <= (text as NSString).length,
           focusedRange.length <= (text as NSString).length - focusedRange.location {
            let color = isDark ? UIColor.white.withAlphaComponent(0.03) : UIColor.black.withAlphaComponent(0.03)
            ranges.append(HighlightedRange(id: "review-focus", range: focusedRange, color: color))
        }
        textView.highlightedRanges = ranges
    }

    /// Coalesce adjacent lines into one wash per added/removed block, including newlines so the
    /// tint fills the row. This avoids seams between individual line highlights in large changes.
    static func diffHighlightRanges(for text: String, tints: [Int: DiffTint], dark: Bool) -> [HighlightedRange] {
        guard !tints.isEmpty else { return [] }
        let palette = EditorTheme.diffPalette(dark: dark)
        var runs: [(range: NSRange, tint: DiffTint)] = []
        var offset = 0
        let parts = text.components(separatedBy: "\n")
        for (index, part) in parts.enumerated() {
            let hasNewline = index < parts.count - 1
            let lineLen = (part as NSString).length
            let lineNo = index + 1
            if let tint = tints[lineNo], !(part.isEmpty && !hasNewline) {
                let length = lineLen + (hasNewline ? 1 : 0)
                if length > 0 {
                    if let previous = runs.last, previous.tint == tint, NSMaxRange(previous.range) == offset {
                        runs[runs.count - 1].range.length += length
                    } else {
                        runs.append((NSRange(location: offset, length: length), tint))
                    }
                }
            }
            offset += lineLen + (hasNewline ? 1 : 0)
        }
        return runs.map {
            HighlightedRange(range: $0.range, color: $0.tint == .added ? palette.addedBg : palette.removedBg)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, TextViewDelegate {
        var text: Binding<String>
        var appliedFontSize: CGFloat = 0
        var appliedDark = false
        var appliedDiffTints: [Int: DiffTint] = [:]
        var appliedFocusedRange: NSRange?
        var diffRanges: [HighlightedRange] = []
        var onSelectionChange: ((String?) -> Void)?
        private var lastSelectionLength = 0
        var lastTextLength = 0
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: TextView) {
            let newLength = (textView.text as NSString).length
            text.wrappedValue = textView.text
            // WORKAROUND (Runestone 0.5.2): cut() collapses the selection through a private path that
            // never notifies UIKit's input delegate, so the pre-cut selection stays highlighted over
            // whatever text shifted up. When a non-empty selection was just removed (text shrank),
            // re-assert the caret via the UITextInput path so UIKit resyncs and clears the highlight.
            if lastSelectionLength > 0, newLength < lastTextLength { forceSelectionResync(textView) }
            lastSelectionLength = 0
            lastTextLength = newLength
        }

        func textViewDidChangeSelection(_ textView: TextView) {
            let range = textView.selectedRange
            lastSelectionLength = range.length
            lastTextLength = (textView.text as NSString).length
            onSelectionChange?(range.length > 0 ? textView.text(in: range) : nil)
        }

        /// Nudge the caret (bump one position then restore, in one runloop so it isn't visible) — the
        /// change makes Runestone flag an input-delegate selection notification, which UIKit needs to
        /// redraw. A no-op set wouldn't trigger it, hence the bump.
        private func forceSelectionResync(_ textView: TextView) {
            let caret = min(textView.selectedRange.location, (textView.text as NSString).length)
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                let len = (textView.text as NSString).length
                let loc = min(caret, len)
                let other = loc == 0 ? min(1, len) : loc - 1
                guard other != loc,
                      let pOther = textView.position(from: textView.beginningOfDocument, offset: other),
                      let pLoc = textView.position(from: textView.beginningOfDocument, offset: loc),
                      let rOther = textView.textRange(from: pOther, to: pOther),
                      let rLoc = textView.textRange(from: pLoc, to: pLoc) else { return }
                textView.selectedTextRange = rOther
                textView.selectedTextRange = rLoc
            }
        }
    }
}

#if DEBUG
extension DiffGutterTextView {
    /// Test/preview helper: configure exactly like `CodeEditorView` with sample text, so a snapshot
    /// test can verify the gutter bars render without importing Runestone into the test target.
    func configureForSnapshot(text: String, dark: Bool) {
        overrideUserInterfaceStyle = dark ? .dark : .light
        showLineNumbers = true
        gutterLeadingPadding = 8
        gutterTrailingPadding = 14
        isLineWrappingEnabled = false
        isEditable = false
        let theme = dark ? EditorTheme.onvo(fontSize: 13) : EditorTheme.light(fontSize: 13)
        backgroundColor = theme.backgroundColor
        setState(TextViewState(text: text, theme: theme))
        setBarColors(dark: dark)
        showBars = true
    }

    /// Test/preview helper: render an inline-diff buffer with red/green line backgrounds (diff-in-editor).
    func configureDiffForSnapshot(text: String, tints: [Int: DiffTint], dark: Bool) {
        configureForSnapshot(text: text, dark: dark)
        showBars = false
        diffTints = tints
        gutterTrailingPadding = max(22, theme.font.pointSize + 8)
        highlightedRanges = CodeEditorView.diffHighlightRanges(for: text, tints: tints, dark: dark)
    }
}
#endif
