import SwiftUI
import XCTest
@testable import Mindwire

final class ChatTextDirectionTests: XCTestCase {
    func testArabicFindsFirstStrongLetterPastNumbersEmojiAndPunctuation() {
        for text in ["مرحبا بالعالم", "123 مرحبا", "١٢٣ أهلاً", "👋 (مرحباً)", "\n\n- أحتاج مساعدة في الكود", "**تم** التحديث", "שלום עולם"] {
            XCTAssertEqual(ChatTextDirection.direction(for: text), .rightToLeft, text)
        }
    }

    func testEnglishAndCodeKeepLeftToRightInMixedConversations() {
        for text in ["Hello مرحبا", "42. Done", "let title = \"مرحبا\"", "✅ Updated the app"] {
            XCTAssertEqual(ChatTextDirection.direction(for: text), .leftToRight, text)
        }
        XCTAssertEqual(ChatTextDirection.direction(for: "راجع `src/app.swift` الآن"), .rightToLeft)
    }

    func testNeutralDraftsInheritAndExplicitDirectionalMarksWork() {
        XCTAssertNil(ChatTextDirection.direction(for: ""))
        XCTAssertNil(ChatTextDirection.direction(for: "123 🔧 ..."))
        XCTAssertEqual(ChatTextDirection.direction(for: "\u{200F}hello"), .rightToLeft)
        XCTAssertEqual(ChatTextDirection.direction(for: "\u{200E}مرحبا"), .leftToRight)
    }
}
