import UIKit
import XCTest
@testable import Mindwire

@MainActor
final class ChatSelectableTextTests: XCTestCase {
    func testRenderedMarkdownKeepsEmphasisCodeAndLinksWithoutDelimiters() throws {
        let text = ChatRenderedText.render("Tap **selection**, *carefully*, `code` and [docs](https://mindwire.sh/docs).",
                                           format: .markdown, style: .init(size: 17))
        XCTAssertEqual(text.string, "Tap selection, carefully, code and docs.")
        let string = text.string as NSString
        let bold = try XCTUnwrap(text.attribute(.font, at: string.range(of: "selection").location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        let italic = try XCTUnwrap(text.attribute(.font, at: string.range(of: "carefully").location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        let code = try XCTUnwrap(text.attribute(.font, at: string.range(of: "code").location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(code.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        let link = try XCTUnwrap(text.attribute(.link, at: string.range(of: "docs").location, effectiveRange: nil) as? URL)
        XCTAssertEqual(link.absoluteString, "https://mindwire.sh/docs")
    }

    func testRawAndUserTextPreserveMarkdownAndLineBreaks() {
        let raw = "# Title\n\nKeep **this** and `that`.\nNext line."
        let rendered = ChatRenderedText.render(raw, format: .plain, style: .init(size: 17))
        XCTAssertEqual(rendered.string, raw)
        let heading = ChatRenderedText.render("## A **heading**\n", format: .markdown, style: .init(size: 20, bold: true))
        XCTAssertEqual(heading.string, "A heading")
    }

    func testCodeHighlightingUsesUTF16RangesAndPreservesFullSource() throws {
        let code = "let title = \"مرحبا 👋🏽\"\n// a comment\nlet count = 42\n"
        let text = ChatRenderedText.render(code, format: .code("swift"), style: .init(size: 15))
        XCTAssertEqual(text.string, code)
        let color = try XCTUnwrap(text.attribute(.foregroundColor, at: (code as NSString).range(of: "42").location,
                                                effectiveRange: nil) as? UIColor)
        XCTAssertFalse(color.isEqual(UIColor.label), "Tokens after non-ASCII text still receive the right color")
        let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.baseWritingDirection, .leftToRight)
    }

    func testArabicRenderedWordsKeepNaturalWritingDirection() throws {
        let text = ChatRenderedText.render("راجع **التغييرات** في `src/app.swift` الآن.", format: .markdown, style: .init(size: 17))
        XCTAssertEqual(text.string, "راجع التغييرات في src/app.swift الآن.")
        let paragraph = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.baseWritingDirection, .natural)
        XCTAssertEqual(paragraph.alignment, .natural)
    }

    func testStreamingAppendKeepsSelectionButChangedBlockClearsIt() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let view = SelectableChatTextView(frame: CGRect(x: 20, y: 100, width: 300, height: 120))
        view.isEditable = false
        window.rootViewController!.view.addSubview(view)
        view.apply(ChatRenderedText.render("Tap **selection** here.", format: .markdown, style: .init(size: 17)), key: "initial")
        XCTAssertTrue(view.becomeFirstResponder())
        let selected = NSRange(location: 4, length: 9)
        view.selectedRange = selected
        view.apply(ChatRenderedText.render("Tap **selection** here. More output.", format: .markdown, style: .init(size: 17)), key: "append")
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertEqual(view.selectedRange, selected)
        // A repeated SwiftUI update does not reassign the text or disturb the native handles.
        let sameText = view.attributedText
        view.apply(sameText!, key: "append")
        XCTAssertEqual(view.attributedText, sameText)
        XCTAssertTrue(view.isFirstResponder)
        XCTAssertEqual(view.selectedRange, selected)
        view.apply(NSAttributedString(string: "A different message."), key: "replacement")
        XCTAssertEqual(view.selectedRange.length, 0)
        XCTAssertFalse(view.isFirstResponder)
    }
}
