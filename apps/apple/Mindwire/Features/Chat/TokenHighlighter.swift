import SwiftUI
import UIKit
import MarkdownUI

/// Lightweight, dependency-free syntax highlighting for fenced code blocks in chat. A single-pass
/// lexer that colors comments, strings, numbers, and per-language keywords; everything else keeps the
/// default text color. The same tokens feed native selectable text and MarkdownUI's `Text`
/// fallback, with colors that adapt to light/dark.
struct TokenHighlighter: CodeSyntaxHighlighter {
    private enum Role { case comment, string, number, keyword }

    func highlightCode(_ code: String, language: String?) -> Text {
        var out = Text("")
        forEachToken(code, language: language) { text, color in
            out = out + (color.map { Text(text).foregroundColor(Color(uiColor: $0)) } ?? Text(text))
        }
        return out
    }

    func highlightCode(_ code: String, language: String?, into text: NSMutableAttributedString) {
        var offset = 0
        forEachToken(code, language: language) { token, color in
            let length = token.utf16.count
            if let color { text.addAttribute(.foregroundColor, value: color, range: NSRange(location: offset, length: length)) }
            offset += length
        }
    }

    private func forEachToken(_ code: String, language: String?, onToken: (String, UIColor?) -> Void) {
        let kws = Self.keywords(for: language)
        let hashComments = Self.usesHashComments(language)
        let chars = Array(code)
        let n = chars.count
        var i = 0

        func emit(_ range: Range<Int>, _ role: Role?) {
            let s = String(chars[range])
            onToken(s, role.map(Self.color))
        }

        while i < n {
            let c = chars[i]

            if c == "/", i + 1 < n, chars[i + 1] == "/" {                 // // line comment
                var j = i; while j < n && chars[j] != "\n" { j += 1 }
                emit(i..<j, .comment); i = j; continue
            }
            if c == "/", i + 1 < n, chars[i + 1] == "*" {                 // /* block comment */
                var j = i + 2
                while j < n && !(chars[j] == "*" && j + 1 < n && chars[j + 1] == "/") { j += 1 }
                if j < n { j += 2 }
                emit(i..<min(j, n), .comment); i = min(j, n); continue
            }
            if c == "#", hashComments {                                   // # line comment
                var j = i; while j < n && chars[j] != "\n" { j += 1 }
                emit(i..<j, .comment); i = j; continue
            }
            if c == "\"" || c == "'" || c == "`" {                        // string literal
                let q = c; var j = i + 1
                while j < n {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == q { j += 1; break }
                    if chars[j] == "\n" && q != "`" { break }
                    j += 1
                }
                emit(i..<min(j, n), .string); i = min(j, n); continue
            }
            if c.isNumber {                                               // number literal
                var j = i
                while j < n, chars[j].isHexDigit || chars[j] == "." || chars[j] == "x" || chars[j] == "_" { j += 1 }
                emit(i..<j, .number); i = j; continue
            }
            if c.isLetter || c == "_" {                                   // identifier / keyword
                var j = i
                while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                emit(i..<j, kws.contains(word) ? .keyword : nil); i = j; continue
            }
            // Plain run (operators, punctuation, whitespace) — batched into one Text node.
            var j = i
            while j < n {
                let d = chars[j]
                if d == "/" || (d == "#" && hashComments) || d == "\"" || d == "'" || d == "`"
                    || d.isNumber || d.isLetter || d == "_" { break }
                j += 1
            }
            if j == i { j += 1 }
            emit(i..<j, nil); i = j
        }
    }

    // MARK: - Palette (dynamic light/dark)

    private static func color(_ role: Role) -> UIColor {
        switch role {
        case .comment: return dyn(light: 0x6E7781, dark: 0x8B949E)
        case .string:  return dyn(light: 0x0A7D33, dark: 0x7EE787)
        case .number:  return dyn(light: 0x953800, dark: 0xF0A868)
        case .keyword: return dyn(light: 0x8250DF, dark: 0xD2A8FF)
        }
    }

    private static func dyn(light: Int, dark: Int) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    // MARK: - Language keyword sets

    private static func usesHashComments(_ language: String?) -> Bool {
        ["python", "py", "ruby", "rb", "bash", "sh", "shell", "zsh", "yaml", "yml", "toml", "r", "perl", "makefile", "dockerfile"]
            .contains((language ?? "").lowercased())
    }

    private static func keywords(for language: String?) -> Set<String> {
        switch (language ?? "").lowercased() {
        case "swift": return swift
        case "js", "javascript", "jsx", "ts", "typescript", "tsx": return jsts
        case "go", "golang": return go
        case "python", "py": return python
        case "rust", "rs": return rust
        case "json": return []
        default: return fallback
        }
    }

    private static let swift: Set<String> = ["func", "let", "var", "if", "else", "guard", "return", "for", "while", "in", "switch", "case", "default", "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "internal", "fileprivate", "static", "self", "init", "nil", "true", "false", "async", "await", "throws", "try", "throw", "do", "catch", "defer", "some", "any", "where", "as", "is", "weak", "lazy", "override", "final", "actor"]
    private static let jsts: Set<String> = ["function", "const", "let", "var", "if", "else", "return", "for", "while", "of", "in", "switch", "case", "default", "class", "extends", "import", "export", "from", "async", "await", "try", "catch", "throw", "new", "this", "null", "undefined", "true", "false", "typeof", "interface", "type", "enum", "public", "private", "readonly", "void", "yield"]
    private static let go: Set<String> = ["func", "var", "const", "if", "else", "for", "range", "switch", "case", "default", "type", "struct", "interface", "package", "import", "return", "go", "defer", "chan", "map", "nil", "true", "false", "select", "break", "continue", "make", "new"]
    private static let python: Set<String> = ["def", "class", "if", "elif", "else", "for", "while", "in", "return", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "None", "True", "False", "and", "or", "not", "is", "async", "await", "yield", "pass", "break", "continue", "global", "self"]
    private static let rust: Set<String> = ["fn", "let", "mut", "if", "else", "for", "while", "loop", "match", "struct", "enum", "trait", "impl", "pub", "use", "mod", "return", "self", "async", "await", "move", "ref", "where", "as", "true", "false", "Some", "None", "Ok", "Err"]
    private static let fallback: Set<String> = ["func", "function", "def", "let", "var", "const", "if", "else", "for", "while", "return", "class", "struct", "enum", "import", "export", "public", "private", "static", "true", "false", "null", "nil", "new", "type", "async", "await", "try", "catch", "throw"]
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
