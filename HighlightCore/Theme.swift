import Foundation

/// Token styles parsed from an Xcode .xccolortheme file.
/// Only foreground colors and bold/italic traits are used; the preview keeps
/// Quick Look's own font, size, and background.
nonisolated struct Theme: Sendable, Equatable {

    struct TokenColor: Sendable, Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    struct Style: Sendable, Equatable {
        var color: TokenColor?
        var bold: Bool = false
        var italic: Bool = false
    }

    /// Keyed by full node type name, e.g. "xcode.syntax.keyword".
    var styles: [String: Style]

    enum ParseError: Error {
        case unreadable(URL)
        case missingSyntaxColors(URL)
    }

    /// Resolves a style for a node type name, trimming trailing components
    /// until a match is found ("xcode.syntax.comment.doc.keyword" falls back
    /// to "xcode.syntax.comment.doc", then "xcode.syntax.comment").
    /// Never resolves past "xcode.syntax.<x>"; unknown types return nil.
    func style(forNodeTypeName name: String) -> Style? {
        var candidate = name
        while candidate.hasPrefix("xcode.syntax."), candidate.count > "xcode.syntax.".count {
            if let style = styles[candidate] { return style }
            guard let dot = candidate.lastIndex(of: ".") else { break }
            candidate = String(candidate[..<dot])
        }
        return nil
    }

    static func load(from url: URL) throws -> Theme {
        guard let plist = NSDictionary(contentsOf: url) else {
            throw ParseError.unreadable(url)
        }
        guard let colors = plist["DVTSourceTextSyntaxColors"] as? [String: String] else {
            throw ParseError.missingSyntaxColors(url)
        }
        let fonts = plist["DVTSourceTextSyntaxFonts"] as? [String: String] ?? [:]

        var styles: [String: Style] = [:]
        for (key, value) in colors {
            var style = Style(color: parseColor(value))
            if let font = fonts[key] {
                let name = fontName(font)
                style.bold = name.contains("Bold") || name.contains("Semibold") || name.contains("Heavy")
                style.italic = name.contains("Italic") || name.contains("Oblique")
            }
            styles[key] = style
        }
        // The plain style would fight Quick Look's own text color; drop it so
        // plain spans reset to the default color instead.
        styles["xcode.syntax.plain"] = nil
        return Theme(styles: styles)
    }

    /// "0.607592 0.137526 0.576284 1" → TokenColor. Exactly four finite
    /// components: junk tokens, NaN, and infinities must not reach NSColor.
    private static func parseColor(_ value: String) -> TokenColor? {
        let parts = value.split(separator: " ")
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite) else { return nil }
        return TokenColor(red: numbers[0], green: numbers[1], blue: numbers[2], alpha: numbers[3])
    }

    /// "SFMono-Semibold - 12.0" → "SFMono-Semibold"
    private static func fontName(_ value: String) -> String {
        if let range = value.range(of: " - ", options: .backwards) {
            return String(value[..<range.lowerBound])
        }
        return value
    }
}
