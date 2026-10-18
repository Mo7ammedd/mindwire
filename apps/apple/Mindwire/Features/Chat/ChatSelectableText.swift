import SwiftUI
import UIKit
import MarkdownUI

enum ChatTextTone: String {
    case primary, secondary, onAccent, onPastel

    var color: UIColor {
        switch self {
        case .primary: .label
        case .secondary: .secondaryLabel
        case .onAccent: UIColor(Palette.onAccent)
        case .onPastel: UIColor(BotColor.ink)
        }
    }
}

private struct ChatTextToneKey: EnvironmentKey {
    static let defaultValue = ChatTextTone.primary
}

struct ChatTextActions {
    var selectRaw: (() -> Void)?
    var editMessage: (() -> Void)?
}

private struct ChatTextActionsKey: EnvironmentKey {
    static let defaultValue = ChatTextActions()
}

/// MarkdownUI identifies blocks by content. Keep the selected message's layout stable
/// until its native selection ends; incoming tokens continue accumulating in ChatModel.
@MainActor @Observable
final class ChatRenderedSelection {
    private(set) var source: String?
    @ObservationIgnored private weak var owner: SelectableChatTextView?

    func update(_ view: SelectableChatTextView, source: String) {
        if view.isFirstResponder && view.selectedRange.length > 0 {
            owner = view
            if self.source == nil { self.source = source }
        } else if owner === view {
            owner = nil
            self.source = nil
        }
    }
}

struct ChatRenderedSelectionContext {
    let state: ChatRenderedSelection
    let source: String
}

private struct ChatRenderedSelectionKey: EnvironmentKey {
    static let defaultValue: ChatRenderedSelectionContext? = nil
}

extension EnvironmentValues {
    var chatTextTone: ChatTextTone {
        get { self[ChatTextToneKey.self] }
        set { self[ChatTextToneKey.self] = newValue }
    }
    var chatTextActions: ChatTextActions {
        get { self[ChatTextActionsKey.self] }
        set { self[ChatTextActionsKey.self] = newValue }
    }
    var chatRenderedSelection: ChatRenderedSelectionContext? {
        get { self[ChatRenderedSelectionKey.self] }
        set { self[ChatRenderedSelectionKey.self] = newValue }
    }
}

/// Keep MarkdownUI's block layout, tables and images. Native text owns word selection
/// inside a text block, including its rendered emphasis, links and inline code.
struct ChatMarkdownBlock<Fallback: View>: View {
    let content: MarkdownContent
    let size: CGFloat
    var bold = false
    var lineSpacing: CGFloat = 0
    var fillsWidth = true
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        if content.renderHTML().contains("<img") {
            fallback()
        } else {
            ChatSelectableText(text: content.renderMarkdown(), size: size, format: .markdown,
                               bold: bold, lineSpacing: lineSpacing, fillsWidth: fillsWidth)
        }
    }
}

struct ChatSelectableText: UIViewRepresentable {
    enum Format: Hashable {
        case plain
        case markdown
        case code(String?)
    }

    let text: String
    let size: CGFloat
    var format: Format = .plain
    var bold = false
    var monospaced = false
    var lineSpacing: CGFloat = 0
    var fillsWidth = true
    var wraps = true
    var tone: ChatTextTone?
    @Environment(\.chatTextTone) private var inheritedTone
    @Environment(\.chatTextActions) private var actions
    @Environment(\.chatRenderedSelection) private var selection
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SelectableChatTextView {
        let view = SelectableChatTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.dataDetectorTypes = []
        view.linkTextAttributes = [.foregroundColor: UIColor(Palette.accent)]
        view.tintColor = UIColor(Palette.accent)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "chat.renderedText"
        view.delegate = context.coordinator
        view.onResign = { [weak view, weak coordinator = context.coordinator] in
            if let view { coordinator?.selectionChanged(view) }
        }
        return view
    }

    func updateUIView(_ view: SelectableChatTextView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.selection = selection
        context.coordinator.openURL = openURL
        let style = ChatRenderedText.Style(size: size, bold: bold, monospaced: monospaced,
                                          lineSpacing: lineSpacing, tone: tone ?? inheritedTone)
        let key = ChatRenderedText.key(text: text, format: format, style: style)
        guard view.renderKey != key else { return }
        view.apply(ChatRenderedText.render(text, format: format, style: style), key: key)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableChatTextView, context: Context) -> CGSize? {
        let natural = uiView.attributedText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let available = proposal.width.flatMap { $0.isFinite ? max(1, $0) : nil }
        let naturalWidth = max(1, ceil(natural.width))
        let width = wraps ? (fillsWidth ? (available ?? naturalWidth) : min(available ?? naturalWidth, naturalWidth)) : naturalWidth
        let measured = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(measured.height))
    }

    static func dismantleUIView(_ view: SelectableChatTextView, coordinator: Coordinator) {
        if view.isFirstResponder { view.resignFirstResponder() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var actions = ChatTextActions()
        var selection: ChatRenderedSelectionContext?
        var openURL: OpenURLAction?

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return openAction(url, textView: textView)
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            guard case .link(let url) = textItem.content else { return .init(menu: defaultMenu) }
            // UIKit's default Open action would try opening a workspace path on the phone.
            return .init(preview: nil, menu: UIMenu(children: [
                openAction(url, textView: textView),
                UIAction(title: t("common.copy"), image: UIImage(named: AppIconName.copy.assetName)) { _ in
                    UIPasteboard.general.url = url
                }
            ]))
        }

        private func openAction(_ url: URL, textView: UITextView) -> UIAction {
            UIAction(title: t("chat.link.open"), image: UIImage(named: AppIconName.arrowUpRight.assetName)) { [weak self, weak textView] _ in
                textView?.resignFirstResponder()
                self?.openURL?(url)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if let view = textView as? SelectableChatTextView { selectionChanged(view) }
        }

        func selectionChanged(_ view: SelectableChatTextView) {
            guard let selection else { return }
            selection.state.update(view, source: selection.source)
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            var messageActions: [UIMenuElement] = []
            if let selectRaw = actions.selectRaw {
                messageActions.append(UIAction(title: t("chat.select")) { [weak textView] _ in
                    textView?.resignFirstResponder()
                    selectRaw()
                })
            }
            if let editMessage = actions.editMessage {
                messageActions.append(UIAction(title: t("chat.fork.title")) { [weak textView] _ in
                    textView?.resignFirstResponder()
                    editMessage()
                })
            }
            return UIMenu(children: messageActions + suggestedActions)
        }
    }
}

/// Reconfiguration and appended streaming tokens keep a selection whose visible prefix
/// has not changed. A recycled/different block never inherits an unrelated selected range.
final class SelectableChatTextView: UITextView {
    fileprivate var renderKey: String?
    var onResign: (() -> Void)?

    @discardableResult override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    func apply(_ value: NSAttributedString, key: String) {
        guard renderKey != key else { return }
        let selected = selectedRange
        let old = (text ?? "") as NSString
        let new = value.string as NSString
        let valid = selected.location != NSNotFound && selected.location <= old.length
            && selected.length <= old.length - selected.location
        let end = valid ? NSMaxRange(selected) : 0
        let preserve = isFirstResponder && selected.length > 0 && valid
            && end <= old.length && end <= new.length
            && old.substring(to: end) == new.substring(to: end)
        attributedText = value
        renderKey = key
        if preserve { selectedRange = selected }
        else {
            selectedRange = NSRange(location: 0, length: 0)
            if isFirstResponder && selected.length > 0 { resignFirstResponder() }
        }
        invalidateIntrinsicContentSize()
    }
}

@MainActor
enum ChatRenderedText {
    struct Style {
        var size: CGFloat
        var bold = false
        var monospaced = false
        var lineSpacing: CGFloat = 0
        var tone: ChatTextTone = .primary
    }

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    static func key(text: String, format: ChatSelectableText.Format, style: Style) -> String {
        "\(format)|\(style.size)|\(style.bold)|\(style.monospaced)|\(style.lineSpacing)|\(style.tone.rawValue)|\(text)"
    }

    static func render(_ text: String, format: ChatSelectableText.Format, style: Style) -> NSAttributedString {
        let key = key(text: text, format: format, style: style) as NSString
        if let value = cache.object(forKey: key) { return value }
        let result: NSMutableAttributedString
        switch format {
        case .markdown:
            var value = (try? AttributedString(markdown: text, options: .init(
                interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
            for run in value.runs {
                let intent = run.inlinePresentationIntent ?? []
                let code = intent.contains(.code)
                let weight: UIFont.Weight = style.bold || intent.contains(.stronglyEmphasized) ? .semibold : .regular
                var font = code || style.monospaced
                    ? UIFont.monospacedSystemFont(ofSize: code ? style.size * 0.9 : style.size, weight: weight)
                    : UIFont.systemFont(ofSize: style.size, weight: weight)
                if intent.contains(.emphasized), let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    font = UIFont(descriptor: descriptor, size: font.pointSize)
                }
                value[run.range].uiKit.font = font
                value[run.range].uiKit.foregroundColor = run.link == nil ? style.tone.color : UIColor(Palette.accent)
                if code { value[run.range].uiKit.backgroundColor = UIColor(Palette.surface) }
                if intent.contains(.strikethrough) { value[run.range].uiKit.strikethroughStyle = .single }
            }
            result = NSMutableAttributedString(attributedString: NSAttributedString(value))
        case .plain, .code:
            let code: Bool
            if case .code = format { code = true } else { code = false }
            let font = code || style.monospaced
                ? UIFont.monospacedSystemFont(ofSize: style.size, weight: style.bold ? .semibold : .regular)
                : UIFont.systemFont(ofSize: style.size, weight: style.bold ? .semibold : .regular)
            result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: style.tone.color])
            if case .code(let language) = format {
                TokenHighlighter().highlightCode(text, language: language, into: result)
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        paragraph.alignment = .natural
        paragraph.baseWritingDirection = .natural
        if case .code = format { paragraph.baseWritingDirection = .leftToRight; paragraph.alignment = .left }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        let immutable = NSAttributedString(attributedString: result)
        cache.setObject(immutable, forKey: key, cost: max(1, result.length * 8))
        return immutable
    }
}
