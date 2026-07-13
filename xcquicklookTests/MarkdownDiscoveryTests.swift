import AppKit
import Foundation
import Testing

/// Markdown typography: emphasis/strong/heading/quote render as font traits.
struct MarkdownTypographyTests {
    @Test func markupSpansCoverConstructsWithoutInternalResets() async throws {
        let doc = "# Heading\n\nSome *emphasis* and **strong** text.\n\n> quoted line\n"
        var hint = LanguageHint()
        hint.contentTypeIdentifiers = ["net.daringfireball.markdown"]
        let result = try await engine.tokenize(text: doc, hint: hint, theme: stubTheme)
        let ns = doc as NSString

        for (type, fragment) in [
            ("xcode.syntax.markup.emphasis", "*emphasis*"),
            ("xcode.syntax.markup.strong", "**strong**"),
            ("xcode.syntax.markup.heading", "# Heading"),
            ("xcode.syntax.markup.quote", "> quoted line"),
        ] {
            #expect(hasSpan(result, type: type, covering: fragment, in: doc), "missing \(fragment)")
            // Trait-only ancestors must not get their content punched out by
            // resets — the italic/bold has to survive on the inner text.
            let range = ns.range(of: fragment)
            let resetInside = result.contains {
                $0.nodeTypeName == nil && NSIntersectionRange($0.range, range).length > 0
            }
            #expect(!resetInside, "reset inside \(fragment)")
        }
    }

    @MainActor
    @Test func renderedTraitsAppearInLivePreview() async throws {
        let doc = "# Title\n\nnormal *ital* and **bold** words\n"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcql-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("note.md")
        try doc.data(using: .utf8)!.write(to: url)

        let controller = PreviewViewController()
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        try await controller.preparePreviewOfFile(at: url)

        func findTextView(in view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
            return nil
        }
        let storage = try #require(findTextView(in: controller.view)?.textStorage)
        let ns = doc as NSString

        func traits(at fragment: String) -> NSFontDescriptor.SymbolicTraits? {
            let range = ns.range(of: fragment)
            guard range.location != NSNotFound, storage.length > range.location else { return nil }
            let font = storage.attributes(at: range.location, effectiveRange: nil)[.font] as? NSFont
            return font?.fontDescriptor.symbolicTraits
        }

        // Poll until the async highlight lands (bold on the strong content).
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if traits(at: "bold")?.contains(.bold) == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(traits(at: "bold")?.contains(.bold) == true)
        #expect(traits(at: "ital")?.contains(.italic) == true)
        #expect(traits(at: "Title")?.contains(.bold) == true)
        #expect(traits(at: "normal ")?.contains(.bold) != true)
        #expect(traits(at: "normal ")?.contains(.italic) != true)
    }
}
