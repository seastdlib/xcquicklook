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

        // Instant, unhighlighted content — the preview is ready as soon as we return.
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: defaultAttributes())
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
                let spans = try await HighlightEngine.shared.tokenize(text: text, hint: hint, theme: theme)
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

    private static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        // NUL bytes near the start mean binary content; let the system handle
        // it. UTF-16/32 text is full of NULs, so honor a BOM first.
        let hasTextBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
            || data.starts(with: [0xFF, 0xFE])
            || data.starts(with: [0xFE, 0xFF])
            || data.starts(with: [0x00, 0x00, 0xFE, 0xFF])
        if !hasTextBOM, data.prefix(8192).contains(0) { return nil }
        // Strict UTF-8 first: it covers ASCII and validates byte structure.
        // Never *suggest* UTF-16 to the detector — it happily misreads
        // even-length ASCII as UTF-16, turning it into CJK mojibake; BOM'd
        // UTF-16/32 is still detected below without the suggestion.
        if !hasTextBOM, let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.suggestedEncodingsKey: [NSUTF8StringEncoding]],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        if encoding != 0, let converted { return converted as String }
        return String(data: data, encoding: .isoLatin1)
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
        func applyBatch(_ batch: some Sequence<TokenSpan>) {
            let length = storage.length
            storage.beginEditing()
            for span in batch {
                guard span.range.location != NSNotFound, NSMaxRange(span.range) <= length else { continue }
                let attrs = attributes(forName: span.nodeTypeName)
                if let color = attrs.color {
                    storage.addAttribute(.foregroundColor, value: color, range: span.range)
                }
                if let font = attrs.font {
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
