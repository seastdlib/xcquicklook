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

    /// Heading size multipliers relative to body text (index 0 = H1), from
    /// the theme's Primary/Secondary/Other heading fonts over its normal
    /// font. Empty when the theme doesn't define markup fonts.
    var headingScales: [Double] = []

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

        // Markdown typography: the source-editor color table doesn't cover
        // emphasis/strong/heading/quote, but the theme's top-level markup
        // keys do. Synthesize trait-only styles — colors stay Quick Look's
        // default, and bold/italic monospace variants are metrically
        // identical, so layout never shifts.
        let markupTraits: [(type: String, fontKey: String, bold: Bool, italic: Bool)] = [
            ("xcode.syntax.markup.emphasis", "DVTMarkupTextEmphasisFont", false, true),
            ("xcode.syntax.markup.strong", "DVTMarkupTextStrongFont", true, false),
            ("xcode.syntax.markup.heading", "DVTMarkupTextPrimaryHeadingFont", true, false),
            ("xcode.syntax.markup.quote", "DVTMarkupTextEmphasisFont", false, true),
        ]
        for entry in markupTraits where styles[entry.type] == nil {
            var style = Style(color: nil, bold: entry.bold, italic: entry.italic)
            if let font = plist[entry.fontKey] as? String {
                let name = fontName(font)
                let bold = name.contains("Bold") || name.contains("Semibold") || name.contains("Heavy")
                let italic = name.contains("Italic") || name.contains("Oblique")
                if bold || italic {
                    style.bold = bold
                    style.italic = italic
                }
            }
            styles[entry.type] = style
        }

        // Heading sizes, expressed as ratios of the theme's own markup body
        // size so nothing is hardcoded and any theme's proportions carry over.
        var theme = Theme(styles: styles)
        if let normal = fontSize(plist["DVTMarkupTextNormalFont"] as? String), normal > 0 {
            for key in ["DVTMarkupTextPrimaryHeadingFont",
                        "DVTMarkupTextSecondaryHeadingFont",
                        "DVTMarkupTextOtherHeadingFont"] {
                if let size = fontSize(plist[key] as? String), size > 0 {
                    theme.headingScales.append(size / normal)
                }
            }
        }
        return theme
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

    /// "HelveticaNeue-Bold - 24.0" → 24.0
    private static func fontSize(_ value: String?) -> Double? {
        guard let value, let range = value.range(of: " - ", options: .backwards) else { return nil }
        let size = Double(value[range.upperBound...].trimmingCharacters(in: .whitespaces))
        guard let size, size.isFinite, size > 0 else { return nil }
        return size
    }
}
