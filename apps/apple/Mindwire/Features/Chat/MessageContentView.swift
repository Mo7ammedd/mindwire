import SwiftUI
import MarkdownUI

/// Renders a message's content.
///
/// - Assistant turns render full **GitHub-Flavored Markdown** via MarkdownUI
///   (cmark-gfm): headings, bold/italic, links, fenced code, blockquotes, ordered/unordered lists,
///   task lists, strikethrough, and **tables**. cmark tolerates partial input, so it stays clean as
///   tokens stream in. It fills the available width (assistant rows are full-width — no avatar).
/// - User turns are plain selectable text that hugs its content. The desktop's neutral bubble
///   changes its text color, never its renderer or width behavior.
struct MessageContentView: View, Equatable {
    let text: String
    var isUserMessage: Bool = false
    @AppStorage(StorageKey.chatTextSize) private var textSizeRaw = ChatTextSize.medium.rawValue
    @State private var selection = ChatRenderedSelection()

    private var base: CGFloat { (ChatTextSize(rawValue: textSizeRaw) ?? .medium).points }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text && lhs.isUserMessage == rhs.isUserMessage }

    var body: some View {
        if isUserMessage {
            ChatSelectableText(text: text, size: base, lineSpacing: 3, fillsWidth: false,
                               tone: ApplePlatform.isDesktop ? .primary : .onAccent)
                .naturalChatDirection(text)
        } else {
            let source = selection.source ?? text
            Markdown(source)
                .markdownTheme(.oblienChat(base: base))
                .markdownCodeSyntaxHighlighter(TokenHighlighter())
                .markdownImageProvider(ChatMarkdownImageProvider())
                .environment(\.chatRenderedSelection, .init(state: selection, source: source))
                .textSelection(.enabled)
                .naturalChatDirection(source, fillWidth: true)
        }
    }
}

private extension MarkdownUI.Theme {
    /// Ultra-minimal chat theme built on `.basic`, parameterised by the user's chosen base size.
    /// The point of this theme is BREATHING ROOM: blocks (paragraphs, headings, lists, code, tables)
    /// were colliding vertically and reading as one run, so the inter-block margins are generous and
    /// scale with the base size. Text stays a comfortable reading size (never the shrunken 15pt).
    /// Adaptive `.primary` text + Oblien accent; SF throughout (clean, not decorated).
    static func oblienChat(base: CGFloat) -> MarkdownUI.Theme {
        let paraGap  = base * 0.95   // clear gap after a paragraph — the main "un-collide" lever
        let headTop  = base * 1.15   // generous breathing room ABOVE a heading
        let headGap  = base * 0.35   // small gap below a heading (it belongs to the block under it)
        let itemGap  = base * 0.5    // between list items — a small, distinct gap (component spacing, not line height)
        let blockGap = base * 0.7    // around code / tables / quotes

        return MarkdownUI.Theme.basic
            .text {
                ForegroundColor(.primary)
                FontSize(base)
            }
            .strong { FontWeight(.semibold) }
            .link { ForegroundColor(Palette.accent) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(Palette.surface)
            }
            .paragraph { configuration in
                ChatMarkdownBlock(content: configuration.content, size: base, lineSpacing: base * 0.25) { configuration.label }
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
                    .relativeLineSpacing(.em(0.25))
                    .markdownMargin(top: 0, bottom: paraGap)
            }
            .heading1 { configuration in
                ChatMarkdownBlock(content: configuration.content, size: base * 1.34, bold: true) { configuration.label }
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
                    .markdownMargin(top: headTop, bottom: headGap)
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.34)) }
            }
            .heading2 { configuration in
                ChatMarkdownBlock(content: configuration.content, size: base * 1.18, bold: true) { configuration.label }
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
                    .markdownMargin(top: headTop, bottom: headGap)
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.18)) }
            }
            .heading3 { configuration in
                ChatMarkdownBlock(content: configuration.content, size: base * 1.06, bold: true) { configuration.label }
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
                    .markdownMargin(top: headTop * 0.8, bottom: headGap)
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.06)) }
            }
            .heading4 { configuration in
                ChatMarkdownBlock(content: configuration.content, size: base, bold: true) { configuration.label }
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
                    .markdownMargin(top: headTop * 0.8, bottom: headGap)
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.0)) }
            }
            .heading5 { configuration in
                ChatMarkdownBlock(content: configuration.content, size: base, bold: true) { configuration.label }
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
                    .markdownMargin(top: headTop * 0.8, bottom: headGap)
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.0)) }
            }
            .heading6 { configuration in
                ChatMarkdownBlock(content: configuration.content, size: base, bold: true) { configuration.label }
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
                    .markdownMargin(top: headTop * 0.8, bottom: headGap)
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.0)) }
            }
            .list { configuration in
                configuration.label.naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
            }
            .listItem { configuration in
                // Tight lists (no blank line between items) IGNORE markdownMargin between items, so a
                // margin gives no visible gap. Real vertical PADDING on each item's label is layout the
                // list can't collapse → a reliable small gap between rows (≈ itemGap total between two
                // adjacent items: half from each).
                configuration.label
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
                    .relativeLineSpacing(.em(0.22))
                    .padding(.vertical, itemGap / 2)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    ChatSelectableText(text: configuration.content, size: base * 0.88, format: .code(configuration.language),
                                       lineSpacing: base * 0.88 * 0.22, fillsWidth: false, wraps: false)
                        .relativeLineSpacing(.em(0.22))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                }
                .environment(\.layoutDirection, .leftToRight)
                .multilineTextAlignment(.leading)
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.88))
                }
                .background(Palette.surfaceAlt.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .markdownMargin(top: blockGap, bottom: blockGap)
            }
            .blockquote { configuration in
                configuration.label
                    .environment(\.chatTextTone, .secondary)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Spacing.md)
                    .markdownMargin(top: blockGap, bottom: blockGap)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Palette.accent.opacity(0.55))
                            .frame(width: 3)
                    }
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
            }
            .table { configuration in
                configuration.label
                    .naturalChatDirection(configuration.content.renderPlainText(), fillWidth: true)
                    .markdownMargin(top: blockGap, bottom: blockGap)
            }
            .tableCell { configuration in
                ChatMarkdownBlock(content: configuration.content, size: base * 0.95, bold: configuration.row == 0,
                                  fillsWidth: false) { configuration.label }
                    .markdownTextStyle { FontSize(.em(0.95)) }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs + 1)
            }
    }
}
