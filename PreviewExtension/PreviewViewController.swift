import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// View-based Quick Look preview: shows the file as plain text immediately
/// (visually identical to the stock plain-text preview) and applies syntax
/// colors asynchronously as the engine produces them.
final class PreviewViewController: NSViewController, QLPreviewingController {

    /// Content types that have richer system previews we must not shadow.
    /// They reach us anyway because they conform to types we claim
    /// (svg → public.xml, csv → public.plain-text).
    private static let excludedTypes: [UTType] = [.html, .svg, .commaSeparatedText]

    private let containerView = AppearanceObservingView()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    private var spans: [TokenSpan] = []
    private var applyTask: Task<Void, Never>?
    private var highlighted = false

    /// Starting point for pixel-parity with the stock preview; tuned empirically.
    private let baseFont: NSFont = .userFixedPitchFont(ofSize: 11)
        ?? .monospacedSystemFont(ofSize: 11, weight: .regular)

    override func loadView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: containerView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        containerView.onAppearanceChange = { [weak self] in
            self?.reapplyForCurrentAppearance()
        }
        view = containerView
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Controllers are reused; clear previous-file state before any await
        // so a mid-flight appearance change can't paint stale spans.
        applyTask?.cancel()
        applyTask = nil
        spans = []
        highlighted = false

        DebugLog.log("prepare: \(url.lastPathComponent)")
        let resources = try? url.resourceValues(forKeys: [.contentTypeKey])
        let contentType = resources?.contentType
        DebugLog.log("contentType: \(contentType?.identifier ?? "nil")")

        if let contentType,
           Self.excludedTypes.contains(where: { contentType.conforms(to: $0) }) {
            DebugLog.log("decline: excluded rendered type")
            throw Self.declineOrFallback(reason: "type has a richer system preview")
        }
        // Without SourceModel we add nothing over the stock previewer.
        guard await HighlightEngine.shared.isAvailable() else {
            DebugLog.log("decline: SourceModel unavailable: \(await HighlightEngine.shared.availabilityFailureDescription() ?? "unknown")")
            throw Self.declineOrFallback(reason: "SourceModel unavailable")
        }
        guard let text = Self.readText(at: url) else {
            DebugLog.log("decline: not decodable as text")
            throw Self.declineOrFallback(reason: "not decodable as text")
        }

        // Minified JSON/JSONL (agent transcripts) gets pretty-printed for
        // display: format enough head material synchronously that the
        // viewport is instantly readable, and stream the rest in as appends —
        // appends never move content the user is already looking at.
        var displayText = text
        var pendingLines: [Substring] = []
        var reformatterSpans: [TokenSpan]?
        if Self.isJSONFamily(contentType: contentType, url: url),
           let job = JSONReformatter.job(for: text) {
            displayText = job.initial
            pendingLines = job.remaining
            reformatterSpans = job.initialSpans
        }

        // Instant content — the preview is ready as soon as we return.
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: displayText, attributes: defaultAttributes())
        )

        var hint = LanguageHint()
        if let contentType {
            hint.contentTypeIdentifiers = [contentType.identifier]
            hint.conformsToSourceCode = contentType.conforms(to: .sourceCode)
        }
        hint.fileExtension = url.pathExtension.isEmpty ? nil : url.pathExtension
        hint.filename = url.lastPathComponent
        hint.firstLine = String(text.prefix(512)).components(separatedBy: .newlines).first

        applyTask = Task { [weak self, dark = isDarkAppearance] in
            do {
                let theme = try await HighlightEngine.shared.theme(dark: dark)

                if var accumulated = reformatterSpans {
                    // Reformatted JSON: the formatter is the authority on
                    // token spans (the display text is no longer valid JSON —
                    // injected newlines would terminate the grammar's string
                    // tokens). Format remaining lines off the main actor in
                    // chunks and colorize each chunk as it appends, so even
                    // huge transcripts get full progressive coloring in O(n).
                    guard let self else { return }
                    self.spans = accumulated
                    await self.apply(spans: accumulated, theme: theme)
                    var index = 0
                    while index < pendingLines.count {
                        let end = min(index + 400, pendingLines.count)
                        let slice = Array(pendingLines[index..<end])
                        let offset = self.textView.textStorage?.length ?? 0
                        let chunk = await Task.detached(priority: .userInitiated) { () -> (String, [TokenSpan]) in
                            var formatted = ""
                            var spans: [TokenSpan] = []
                            for line in slice {
                                let (text, lineSpans) = JSONReformatter.reindentWithSpans(
                                    line, utf16Offset: offset + formatted.utf16.count
                                )
                                formatted += text
                                formatted += "\n\n"
                                spans.append(contentsOf: lineSpans)
                            }
                            return (formatted, spans)
                        }.value
                        guard !Task.isCancelled else { return }
                        self.textView.textStorage?.append(
                            NSAttributedString(string: chunk.0, attributes: self.defaultAttributes())
                        )
                        await self.apply(spans: chunk.1, theme: theme)
                        accumulated.append(contentsOf: chunk.1)
                        self.spans = accumulated
                        index = end
                        await Task.yield()
                    }
                    self.highlighted = true
                    DebugLog.log("reformatted+colored \(url.lastPathComponent): \(accumulated.count) spans")
                    if self.isDarkAppearance != dark {
                        self.reapplyForCurrentAppearance()
                    }
                    return
                }

                let spans = try await HighlightEngine.shared.tokenize(text: displayText, hint: hint, theme: theme)
                DebugLog.log("tokenized \(url.lastPathComponent): \(spans.count) spans")
                guard !Task.isCancelled, let self else { return }
                self.spans = spans
                await self.apply(spans: spans, theme: theme)
                self.highlighted = true
                DebugLog.log("applied \(spans.count) spans to \(url.lastPathComponent)")
                // The appearance may have flipped while we were tokenizing.
                if self.isDarkAppearance != dark {
                    self.reapplyForCurrentAppearance()
                }
            } catch {
                // No language, oversized file, or engine failure: stay plain.
                DebugLog.log("highlight failed for \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// JSON and JSON Lines files, by declared type or extension.
    private static func isJSONFamily(contentType: UTType?, url: URL) -> Bool {
        if let id = contentType?.identifier,
           id == "public.json" || id == "public.ndjson" {
            return true
        }
        let ext = url.pathExtension.lowercased()
        return ext == "json" || ext == "jsonl" || ext == "ndjson"
    }

    deinit {
        applyTask?.cancel()
    }

    /// Single switch point for the no-highlighting strategy: currently decline
    /// so macOS falls back to its own previewer. If that fallback proves ugly,
    /// return nil here and let callers continue with plain text instead.
    private static func declineOrFallback(reason: String) -> any Error {
        CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    // MARK: Text loading

    // Internal (not private) so the test bundle can exercise encoding handling.
    static func readText(at url: URL) -> String? {
        // Deliberately NOT memory-mapped: a mapped file that gets truncated
        // mid-preview (log rotation, atomic saves) turns every later access
        // into SIGBUS. Text previews are small enough to read outright.
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeText(data)
    }

    /// Decoding ladder: explicit BOM dispatch (with the BOM stripped so it
    /// never renders as a glyph), then a NUL-parity signature for BOM-less
    /// UTF-16, then strict UTF-8, then platform detection, then Latin-1.
    /// UTF-16 is never *suggested* to the platform detector — it happily
    /// misreads even-length ASCII as UTF-16, producing CJK mojibake.
    static func decodeText(_ data: Data) -> String? {
        // UTF-32 BOMs first: the UTF-32LE BOM starts with the UTF-16LE BOM.
        // BOM branches fall through on failed or garbage decodes rather than
        // declining outright.
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]), data.count % 4 == 0,
           let utf32 = String(data: data.dropFirst(4), encoding: .utf32BigEndian),
           looksLikeText(utf32) {
            return utf32
        }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]), data.count % 4 == 0,
           let utf32 = String(data: data.dropFirst(4), encoding: .utf32LittleEndian),
           looksLikeText(utf32) {
            return utf32
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let utf8 = String(data: data.dropFirst(3), encoding: .utf8) {
            return utf8
        }
        if data.starts(with: [0xFF, 0xFE]),
           let utf16 = String(data: data.dropFirst(2), encoding: .utf16LittleEndian),
           looksLikeText(utf16) {
            return utf16
        }
        if data.starts(with: [0xFE, 0xFF]),
           let utf16 = String(data: data.dropFirst(2), encoding: .utf16BigEndian),
           looksLikeText(utf16) {
            return utf16
        }

        // NUL analysis over the WHOLE file (strict UTF-8 would happily accept
        // embedded NULs, so an ASCII head with a binary NUL tail must be
        // caught here): text encodings other than UTF-16/32 never contain
        // NULs, but BOM-less UTF-16 of ASCII-ish text is ~half NULs, all on
        // one byte parity. Anything else NUL-laden is binary. The
        // looksLikeText gate catches the false positive this heuristic alone
        // would admit: binary tables of small 16-bit integers share the NUL
        // parity signature but decode to control-character soup.
        if data.contains(0) {
            let sample = data.prefix(8192)
            var evenNULs = 0
            var oddNULs = 0
            for (offset, byte) in sample.enumerated() where byte == 0 {
                if offset.isMultiple(of: 2) { evenNULs += 1 } else { oddNULs += 1 }
            }
            if data.count % 2 == 0, (evenNULs + oddNULs) * 3 >= sample.count {
                if oddNULs > evenNULs * 8,
                   let utf16 = String(data: data, encoding: .utf16LittleEndian),
                   looksLikeText(utf16) {
                    return utf16
                }
                if evenNULs > oddNULs * 8,
                   let utf16 = String(data: data, encoding: .utf16BigEndian),
                   looksLikeText(utf16) {
                    return utf16
                }
            }
            return nil
        }

        // Strict UTF-8 covers ASCII and validates byte structure.
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        // Lossy conversion must be forbidden: the detector would otherwise
        // pick UTF-8 for mostly-ASCII Latin-1 and replace every accent with
        // U+FFFD instead of letting the Latin-1 rung decode them.
        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [NSUTF8StringEncoding],
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if encoding != 0, let converted { return converted as String }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Heuristic gate for UTF-16/32 decodes: real text is not dominated by
    /// control characters (tab/newline/CR excepted).
    private static func looksLikeText(_ string: String) -> Bool {
        var total = 0
        var control = 0
        for scalar in string.unicodeScalars.prefix(4096) {
            total += 1
            let v = scalar.value
            if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D) || (0x7F...0x9F).contains(v) {
                control += 1
            }
        }
        guard total > 0 else { return true }
        return control * 20 < total  // <5% control characters
    }

    // MARK: Attribute application

    private var isDarkAppearance: Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func defaultAttributes() -> [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor]
    }

    private func styledFont(bold: Bool, italic: Bool) -> NSFont {
        var font = baseFont
        let manager = NSFontManager.shared
        if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private func color(for tokenColor: Theme.TokenColor) -> NSColor {
        NSColor(srgbRed: tokenColor.red, green: tokenColor.green, blue: tokenColor.blue, alpha: tokenColor.alpha)
    }

    private func visibleCharacterRange() -> NSRange {
        // TextKit 2 only: touching textView.layoutManager would silently
        // downgrade the view to TextKit 1 compatibility mode.
        guard !textView.visibleRect.isEmpty,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else {
            return NSRange(location: 0, length: 0)
        }
        let document = layoutManager.documentRange
        let location = contentManager.offset(from: document.location, to: viewport.location)
        let length = contentManager.offset(from: viewport.location, to: viewport.endLocation)
        guard location >= 0, length > 0 else { return NSRange(location: 0, length: 0) }
        return NSRange(location: location, length: length)
    }

    private func apply(spans: [TokenSpan], theme: Theme) async {
        guard let storage = textView.textStorage else { return }
        let visible = visibleCharacterRange()

        var visibleSpans: [TokenSpan] = []
        var remaining: [TokenSpan] = []
        if visible.length > 0 {
            for span in spans {
                if NSIntersectionRange(span.range, visible).length > 0 {
                    visibleSpans.append(span)
                } else {
                    remaining.append(span)
                }
            }
        } else {
            remaining = spans
        }

        // Resolve each node type name to concrete attributes once, not per span.
        var resolved: [String: (color: NSColor?, font: NSFont?)] = [:]
        var fontCache: [String: NSFont] = [:]
        func attributes(forName name: String?) -> (color: NSColor?, font: NSFont?) {
            guard let name else { return (NSColor.textColor, baseFont) }
            if let cached = resolved[name] { return cached }
            var result: (color: NSColor?, font: NSFont?) = (nil, nil)
            if let style = theme.style(forNodeTypeName: name) {
                result.color = style.color.map(color(for:))
                if style.bold || style.italic {
                    let key = (style.bold ? "b" : "") + (style.italic ? "i" : "")
                    let font = fontCache[key] ?? styledFont(bold: style.bold, italic: style.italic)
                    fontCache[key] = font
                    result.font = font
                }
            } else {
                // Explicit reset: unstyled code inside a styled ancestor.
                result = (NSColor.textColor, baseFont)
            }
            resolved[name] = result
            return result
        }
        // Markdown headings scale by level (H1 > H2 > H3+) using the theme's
        // own heading/body size ratios; level comes from the leading # count
        // since the spec emits a single heading node type.
        var headingFonts: [Int: NSFont] = [:]
        func headingFont(forLevel level: Int) -> NSFont? {
            guard !theme.headingScales.isEmpty else { return nil }
            let index = min(max(level, 1), theme.headingScales.count) - 1
            if let cached = headingFonts[index] { return cached }
            let bold = styledFont(bold: true, italic: false)
            let font = NSFontManager.shared.convert(bold, toSize: bold.pointSize * theme.headingScales[index])
            headingFonts[index] = font
            return font
        }
        func headingLevel(of range: NSRange) -> Int {
            let text = (storage.string as NSString).substring(with: range)
            return text.drop(while: { $0 == " " }).prefix(while: { $0 == "#" }).count
        }

        func applyBatch(_ batch: some Sequence<TokenSpan>) {
            let length = storage.length
            storage.beginEditing()
            for span in batch {
                guard span.range.location != NSNotFound, NSMaxRange(span.range) <= length else { continue }
                let attrs = attributes(forName: span.nodeTypeName)
                if let color = attrs.color {
                    storage.addAttribute(.foregroundColor, value: color, range: span.range)
                }
                if span.nodeTypeName == "xcode.syntax.markup.heading",
                   let font = headingFont(forLevel: headingLevel(of: span.range)) {
                    storage.addAttribute(.font, value: font, range: span.range)
                } else if let font = attrs.font {
                    storage.addAttribute(.font, value: font, range: span.range)
                }
            }
            storage.endEditing()
        }

        applyBatch(visibleSpans)
        for chunk in stride(from: 0, to: remaining.count, by: 4000) {
            await Task.yield()
            if Task.isCancelled { return }
            applyBatch(remaining[chunk..<min(chunk + 4000, remaining.count)])
        }
    }

    private func reapplyForCurrentAppearance() {
        guard highlighted, !spans.isEmpty else { return }
        applyTask?.cancel()
        applyTask = Task { [weak self, dark = isDarkAppearance] in
            guard let theme = try? await HighlightEngine.shared.theme(dark: dark),
                  let self, !Task.isCancelled else { return }
            if let storage = self.textView.textStorage {
                storage.setAttributes(self.defaultAttributes(), range: NSRange(location: 0, length: storage.length))
            }
            await self.apply(spans: self.spans, theme: theme)
        }
    }
}

/// NSView that reports effective appearance changes (light/dark switches).
private final class AppearanceObservingView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
