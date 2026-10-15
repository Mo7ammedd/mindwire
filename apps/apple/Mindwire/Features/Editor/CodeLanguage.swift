import Foundation
import Runestone
import TreeSitterBashRunestone
import TreeSitterCPPRunestone
import TreeSitterCRunestone
import TreeSitterCSSRunestone
import TreeSitterGoRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPythonRunestone
import TreeSitterRubyRunestone
import TreeSitterRustRunestone
import TreeSitterSwiftRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone

/// Maps a filename to a tree-sitter language for syntax highlighting. An unknown extension returns
/// `nil` — Runestone then renders the file as plain text, which is the right fallback.
enum CodeLanguage {
    static func language(for name: String) -> TreeSitterLanguage? {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javaScript
        case "ts", "mts", "cts": return .typeScript
        case "tsx": return .tsx
        case "py", "pyw": return .python
        case "go": return .go
        case "rs": return .rust
        case "json", "jsonc": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown": return .markdown
        case "html", "htm": return .html
        case "css": return .css
        case "sh", "bash", "zsh": return .bash
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hh": return .cpp
        case "java": return .java
        case "rb": return .ruby
        default: return nil
        }
    }
}
