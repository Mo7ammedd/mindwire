import Runestone
import UIKit

/// Runestone `Theme` for the code editor. The dark theme is the **onvo** palette harvested from the
/// axios reference (color values only); a clean light variant keeps the editor legible in light mode.
/// Instances are shared singletons (`.onvo` / `.light`) so the SwiftUI wrapper can compare by identity
/// and only re-apply the theme when it actually changes.
///
/// `Runestone.Theme` carries no editor-background color — that's the `TextView.backgroundColor` — so
/// `backgroundColor`/`caretColor` here are extra fields the wrapper applies to the view directly.
final class EditorTheme: Runestone.Theme {
    let font: UIFont
    let textColor: UIColor
    let backgroundColor: UIColor
    let caretColor: UIColor
    let gutterBackgroundColor: UIColor
    let gutterHairlineColor: UIColor
    let lineNumberColor: UIColor
    let lineNumberFont: UIFont
    let selectedLineBackgroundColor: UIColor
    let selectedLinesLineNumberColor: UIColor
    let selectedLinesGutterBackgroundColor: UIColor
    let invisibleCharactersColor: UIColor
    let pageGuideHairlineColor: UIColor
    let pageGuideBackgroundColor: UIColor
    let markedTextBackgroundColor: UIColor

    /// The editor text point size this theme was built with (app-wide, user-adjustable).
    let fontSize: CGFloat
    private let tokenColors: [String: UIColor]

    init(fontSize: CGFloat, textColor: UIColor, backgroundColor: UIColor, caretColor: UIColor,
         gutterBackgroundColor: UIColor, lineNumberColor: UIColor, selectedLineBackgroundColor: UIColor,
         invisibleCharactersColor: UIColor,
         tokenColors: [String: UIColor]) {
        self.fontSize = fontSize
        self.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.caretColor = caretColor
        // Transparent gutter/page-guide so the editor blends into the modal's native surface.
        self.gutterBackgroundColor = .clear
        self.gutterHairlineColor = .clear
        self.lineNumberColor = lineNumberColor
        self.lineNumberFont = UIFont.monospacedSystemFont(ofSize: max(9, fontSize - 3), weight: .regular)
        self.selectedLineBackgroundColor = selectedLineBackgroundColor
        self.selectedLinesLineNumberColor = textColor
        self.selectedLinesGutterBackgroundColor = .clear
        self.invisibleCharactersColor = invisibleCharactersColor
        self.pageGuideHairlineColor = .clear
        self.pageGuideBackgroundColor = .clear
        self.markedTextBackgroundColor = selectedLineBackgroundColor
        self.tokenColors = tokenColors
    }

    /// Map a tree-sitter capture name to a color. Falls back from a dotted name to its root
    /// (`keyword.control` → `keyword`); unmapped names use the default text color.
    func textColor(for highlightName: String) -> UIColor? {
        if let exact = tokenColors[highlightName] { return exact }
        if let dot = highlightName.firstIndex(of: ".") {
            return tokenColors[String(highlightName[..<dot])]
        }
        return nil
    }

    // MARK: - Git colors (theme-driven, shared by the editor gutter bars + the flat diff)

    /// Solid VS Code-style gutter-bar colors: green added, blue modified, red removed.
    static func gutterColors(dark: Bool) -> (added: UIColor, modified: UIColor, removed: UIColor) {
        let palette = diffPalette(dark: dark)
        return (palette.addedText, UIColor(hex: dark ? 0x539BF5 : 0x0969DA), palette.removedText)
    }

    /// Monokai Pro green/pink-red, matching the bundled file icons. Counts and change markers
    /// stay opaque; only line backgrounds blend into the native surface. Deeper variants keep
    /// light-mode labels and dark-mode syntax readable, including on elevated sheet surfaces.
    /// Shared by open diffs, previews, change counts, and file gutter decorations.
    struct DiffPalette { let addedText, addedBg, removedText, removedBg: UIColor }
    static func diffPalette(dark: Bool) -> DiffPalette {
        let backgroundAlpha: CGFloat = dark ? 0.12 : 0.10
        return DiffPalette(
            addedText: UIColor(hex: dark ? 0xA9DC76 : 0x4A6D24),
            addedBg: UIColor(hex: dark ? 0x8CBA5A : 0x4A6D24, alpha: backgroundAlpha),
            removedText: UIColor(hex: dark ? 0xFF6188 : 0xB22A50),
            removedBg: UIColor(hex: dark ? 0xFF6188 : 0xB22A50, alpha: backgroundAlpha)
        )
    }

    // MARK: - Palettes

    /// onvo (dark) — the harvested default. Plain identifiers stay the default text color to avoid the
    /// "everything is colored" look; the distinctive tokens carry onvo's accents.
    static func onvo(fontSize: CGFloat) -> EditorTheme { EditorTheme(
        fontSize: fontSize,
        textColor: UIColor(hex: 0xDCE0E6),
        backgroundColor: UIColor(hex: 0x151515),
        caretColor: Palette.accentColor(for: .dark),
        gutterBackgroundColor: UIColor(hex: 0x151515),
        lineNumberColor: UIColor(hex: 0x9BA5B2),
        selectedLineBackgroundColor: UIColor(hex: 0x252323),
        invisibleCharactersColor: UIColor(hex: 0x4F4D4D),
        tokenColors: [
            "comment": UIColor(hex: 0xA6AEBB),
            "string": UIColor(hex: 0xD9BF8C),
            "number": UIColor(hex: 0xDBAB8C),
            "keyword": UIColor(hex: 0xBCABD7),
            "operator": UIColor(hex: 0xA2B9C7),
            "function": UIColor(hex: 0xD2D8E3),
            "type": UIColor(hex: 0x9CB6D7),
            "constant": UIColor(hex: 0x9CB6D7),
            "constructor": UIColor(hex: 0x9CB6D7),
        ]
    ) }

    /// Clean light variant (GitHub-light-ish) so light-mode users aren't blinded by a dark editor.
    static func light(fontSize: CGFloat) -> EditorTheme { EditorTheme(
        fontSize: fontSize,
        textColor: UIColor(hex: 0x1F2328),
        backgroundColor: UIColor(hex: 0xFFFFFF),
        caretColor: Palette.accentColor(for: .light),
        gutterBackgroundColor: UIColor(hex: 0xFFFFFF),
        lineNumberColor: UIColor(hex: 0x657080),
        selectedLineBackgroundColor: UIColor(hex: 0xF2F2F5),
        invisibleCharactersColor: UIColor(hex: 0xD0D7DE),
        tokenColors: [
            "comment": UIColor(hex: 0x4C5663),
            "string": UIColor(hex: 0x0A3069),
            "number": UIColor(hex: 0x0550AE),
            "keyword": UIColor(hex: 0xA6202E),
            "operator": UIColor(hex: 0x0550AE),
            "function": UIColor(hex: 0x6639BA),
            "type": UIColor(hex: 0x953800),
            "constant": UIColor(hex: 0x0550AE),
            "constructor": UIColor(hex: 0x953800),
        ]
    ) }
}

private extension UIColor {
    /// 0xRRGGBB, optional alpha (defaults opaque).
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
