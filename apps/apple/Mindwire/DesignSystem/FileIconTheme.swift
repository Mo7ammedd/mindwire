import CoreText
import SwiftUI
import UIKit

/// Monokai Pro file icons — a VS Code **font-based** icon theme. The `.woff` was converted to `.ttf`
/// (iOS can't load WOFF) and registered at first use; the `*.icontheme.json` maps a filename or
/// extension to a glyph + color.
///
/// Only returns a themed glyph for a KNOWN, specific type — a file with no/unknown extension (or one
/// that only maps to the generic `_default`) returns nil so the caller uses the catalog icon,
/// exactly like folders keep the catalog folder icon. Extension coverage comes from two places in the
/// theme: `fileExtensions` (direct) and `languageIds` (via our `extToLanguageId` bridge, since VS
/// Code resolves most code files by language, not raw extension).
final class FileIconTheme {
    static let shared = FileIconTheme()
    static let fontName = "monokai_pro_icons"
    /// Folder tint — Monokai Pro orange (#FC9867), not the app's Oblien accent.
    static let folderColor = Color(red: 252 / 255, green: 152 / 255, blue: 103 / 255)

    struct Icon { let char: String; let color: Color }

    /// True once the icon font is registered — if not, callers use the catalog fallback.
    let available: Bool

    private var defs: [String: (scalar: UInt32, color: Color)] = [:]
    private var extMap: [String: String] = [:]        // fileExtensions:  "tsx" → "_react"
    private var nameMap: [String: String] = [:]        // fileNames:       "package.json" → "_npm"
    private var langMap: [String: String] = [:]        // languageIds:     "javascript" → "_js"
    private var fileDefault = "_default"
    private var folderId = "_folder"

    private init() {
        available = Self.registerFont()
        load()
    }

    /// Resolve a FILE name to a themed glyph + color, or nil to fall back to the catalog icon.
    /// (Folders are rendered natively by the caller.)
    func icon(for name: String) -> Icon? {
        guard available else { return nil }
        let lower = name.lowercased()
        // 1. exact filename (e.g. Dockerfile, package.json)
        if let id = nameMap[lower], let ic = icon(defId: id) { return ic }
        // 2. direct extension match (compound-aware, longest first — e.g. blade.php)
        if let id = longestExtMatch(lower), let ic = icon(defId: id) { return ic }
        // 3. last extension → VS Code languageId → theme icon (covers js/py/json/md/go/… )
        if let dot = lower.lastIndex(of: "."), dot < lower.index(before: lower.endIndex) {
            let ext = String(lower[lower.index(after: dot)...])
            if let lang = Self.extToLanguageId[ext], let id = langMap[lang], let ic = icon(defId: id) { return ic }
        }
        return nil
    }

    /// A specific icon for `id`, or nil when it's the generic default (→ caller uses the catalog icon).
    private func icon(defId id: String) -> Icon? {
        guard id != fileDefault, let d = defs[id], let scalar = UnicodeScalar(d.scalar) else { return nil }
        return Icon(char: String(scalar), color: d.color)
    }

    /// Longest matching extension first (`foo.blade.php` → `blade.php` before `php`).
    private func longestExtMatch(_ lower: String) -> String? {
        let parts = lower.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        for i in 1..<parts.count {
            if let id = extMap[parts[i...].joined(separator: ".")] { return id }
        }
        return nil
    }

    /// Common extension → VS Code languageId (the theme keys icons by languageId, not raw extension).
    /// Missing/`_default`-mapped languages fall through to the catalog icon.
    static let extToLanguageId: [String: String] = [
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "javascriptreact",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
        "py": "python", "pyw": "python", "pyi": "python",
        "rb": "ruby", "gemspec": "ruby",
        "go": "go", "rs": "rust", "java": "java",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "m": "objective-c", "mm": "objective-cpp", "cs": "csharp",
        "css": "css", "scss": "scss", "sass": "sass", "less": "less",
        "html": "html", "htm": "html", "xhtml": "html", "xml": "xml",
        "json": "json", "jsonc": "jsonc", "json5": "jsonc",
        "md": "markdown", "markdown": "markdown", "mdx": "mdx",
        "sh": "shellscript", "bash": "shellscript", "zsh": "shellscript", "ksh": "shellscript",
        "ps1": "powershell", "psm1": "powershell",
        "yml": "yaml", "yaml": "yaml", "toml": "toml", "sql": "sql",
        "lua": "lua", "php": "php", "pl": "perl", "pm": "perl", "r": "r", "dart": "dart",
        "clj": "clojure", "cljs": "clojure", "hs": "haskell",
        "ex": "elixir", "exs": "elixir", "erl": "erlang", "hrl": "erlang",
        "ml": "ocaml", "mli": "ocaml", "coffee": "coffeescript",
        "vue": "vue", "svelte": "svelte", "swift": "swift", "tex": "latex",
        "graphql": "graphql", "gql": "graphql",
    ]

    private static func registerFont() -> Bool {
        if UIFont(name: fontName, size: 12) != nil { return true }   // already registered
        guard let url = Bundle.main.url(forResource: fontName, withExtension: "ttf") else { return false }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return UIFont(name: fontName, size: 12) != nil
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "monokai_pro_icons.icontheme", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let f = root["file"] as? String { fileDefault = f }
        if let f = root["folder"] as? String { folderId = f }
        if let d = root["iconDefinitions"] as? [String: [String: Any]] {
            for (id, v) in d {
                guard let fc = v["fontCharacter"] as? String, let scalar = Self.parseScalar(fc) else { continue }
                let color = (v["fontColor"] as? String).map(Self.color(fromHex:)) ?? .secondary
                defs[id] = (scalar, color)
            }
        }
        extMap = ((root["fileExtensions"] as? [String: String]) ?? [:])
            .reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        nameMap = ((root["fileNames"] as? [String: String]) ?? [:])
            .reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        langMap = (root["languageIds"] as? [String: String]) ?? [:]
    }

    /// `"\FF101"`-style fontCharacter → Unicode scalar value.
    private static func parseScalar(_ fontCharacter: String) -> UInt32? {
        var s = fontCharacter
        while s.first == "\\" { s.removeFirst() }
        return UInt32(s, radix: 16)
    }

    private static func color(fromHex hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt32(s, radix: 16) else { return .secondary }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

/// A FILE type icon: the Monokai Pro themed glyph for known extensions, else the catalog icon.
/// Folders are drawn with the catalog folder icon by callers (this is files-only).
struct FileIcon: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        if let icon = FileIconTheme.shared.icon(for: name) {
            Text(icon.char)
                .font(.custom(FileIconTheme.fontName, size: size))
                .foregroundStyle(icon.color)
        } else {
            AppIcon(fileTypeIcon(name), size: size)
                .foregroundStyle(.secondary)
        }
    }
}
