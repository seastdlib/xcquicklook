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

    @Test func installedThemesCarryDescendingHeadingScales() async throws {
        for dark in [false, true] {
            let theme = try await engine.theme(dark: dark)
            let scales = theme.headingScales
            try #require(!scales.isEmpty)
            #expect(scales[0] > 1.0)
            #expect(scales == scales.sorted(by: >), "scales should descend: \(scales)")
        }
    }

    @MainActor
    @Test func headingLevelsRenderAtDescendingSizes() async throws {
        let doc = "# One\n## Two\n### Three\nbody text\n"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcql-md-h-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("h.md")
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
        func pointSize(at fragment: String) -> CGFloat? {
            let range = ns.range(of: fragment)
            guard range.location != NSNotFound, storage.length > range.location else { return nil }
            return (storage.attributes(at: range.location, effectiveRange: nil)[.font] as? NSFont)?.pointSize
        }

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let one = pointSize(at: "One"), let body = pointSize(at: "body"), one > body { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let h1 = try #require(pointSize(at: "One"))
        let h2 = try #require(pointSize(at: "Two"))
        let h3 = try #require(pointSize(at: "Three"))
        let body = try #require(pointSize(at: "body"))
        #expect(h1 > h2)
        #expect(h2 > h3 || h2 == h3)  // themes may share H2/H3 sizes
        #expect(h3 > body)
    }

    @MainActor
    @Test func emphasisInsideHeadingKeepsHeadingSize() async throws {
        let doc = "# Title *word* end\n\nbody\n"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcql-md-e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("e.md")
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
        func font(at fragment: String) -> NSFont? {
            let range = ns.range(of: fragment)
            guard range.location != NSNotFound, storage.length > range.location else { return nil }
            return storage.attributes(at: range.location, effectiveRange: nil)[.font] as? NSFont
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let title = font(at: "Title"), let body = font(at: "body"), title.pointSize > body.pointSize { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let title = try #require(font(at: "Title"))
        let word = try #require(font(at: "word"))
        let body = try #require(font(at: "body"))
        // The emphasized word keeps the heading's enlarged size and gains italic.
        #expect(word.pointSize == title.pointSize)
        #expect(word.pointSize > body.pointSize)
        #expect(word.fontDescriptor.symbolicTraits.contains(.italic))
    }

    @Test func headingScalesNeverShrinkBelowBody() throws {
        let plist: [String: Any] = [
            "DVTSourceTextSyntaxColors": ["xcode.syntax.keyword": "0.1 0.2 0.3 1"],
            "DVTMarkupTextNormalFont": "Helvetica - 12.0",
            "DVTMarkupTextSecondaryHeadingFont": "Helvetica-Bold - 10.0",
            "DVTMarkupTextOtherHeadingFont": "Helvetica-Bold - 8.0",
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("small-\(UUID().uuidString).xccolortheme")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        let theme = try Theme.load(from: url)
        #expect(theme.headingScales.allSatisfy { $0 >= 1.0 })
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
