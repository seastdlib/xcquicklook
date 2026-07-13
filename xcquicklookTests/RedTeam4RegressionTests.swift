import AppKit
import Foundation
import Testing

/// Regressions for adversary round 4 plus pinned invariants from its passes.
struct RedTeam4RegressionTests {
    @Test func escapedSpacePathsAreStillDeps() {
        // clang -MD escapes spaces; projects under "Application Support" or
        // spaced DerivedData paths emit them in every deps file.
        let ruled = "build\\ dir/main.o: src/main.c \\\n  src/main.h\n"
        #expect(LanguageDetector.looksLikeMakeDependencies(forTextPrefix: ruled))
        let fragment = "/Users/me/Library/Application\\ Support/hdr.h \\\n/usr/include/stdio.h \\\n"
        #expect(LanguageDetector.looksLikeMakeDependencies(forTextPrefix: fragment))
        // A bare (unescaped) space still disqualifies.
        #expect(!LanguageDetector.looksLikeMakeDependencies(forTextPrefix: "some prose: not a rule\nmore words here\n"))
    }

    @Test func commentHeaderDoesNotExhaustDepsWindow() {
        var deps = ""
        for i in 0..<12 { deps += "# generated header line \(i)\n" }
        deps += "main.o: src/main.c src/main.h\n"
        #expect(LanguageDetector.looksLikeMakeDependencies(forTextPrefix: deps))
    }

    @Test func keywordSpansNeverStartMidIdentifier() {
        for input in ["{\"a\":\"s\" xtrue}", "{\"a\":1e2true}", "{\"ok\":true}"] {
            let (text, spans) = JSONReformatter.reindentWithSpans(input[...], utf16Offset: 0)
            let ns = text as NSString
            for span in spans where span.nodeTypeName == "xcode.syntax.keyword" {
                if span.range.location > 0 {
                    let prev = ns.substring(with: NSRange(location: span.range.location - 1, length: 1))
                    #expect(prev.rangeOfCharacter(from: .alphanumerics) == nil && prev != "_",
                            "keyword span mid-identifier in \(text)")
                }
            }
        }
        // Well-formed keywords still get spans.
        let (_, spans) = JSONReformatter.reindentWithSpans("{\"ok\":true}"[...], utf16Offset: 0)
        #expect(spans.contains { $0.nodeTypeName == "xcode.syntax.keyword" })
    }

    /// Pinned invariant from round 4's passes: mirroring the controller's
    /// chunked streaming (head job + 400-line chunks + "\n\n" separators),
    /// every emitted span must substring-match the final concatenated text.
    @Test func streamedChunkSpanOffsetsMatchConcatenatedText() {
        let line = "{\"ok\":true,\"msg\":\"hé🎉 \\\"q\\\" and\\nmore " + String(repeating: "pad🎉 ", count: 40) + "\",\"n\":-1.25e+3}"
        let text = Array(repeating: line, count: 950).joined(separator: "\n")
        guard let job = JSONReformatter.job(for: text, expandNewlines: true) else {
            Issue.record("job unexpectedly nil")
            return
        }
        var full = job.initial
        var spans = job.initialSpans
        var index = 0
        let remaining = job.remaining
        while index < remaining.count {
            let end = min(index + 400, remaining.count)
            let offset = full.utf16.count
            var formattedUTF16 = 0
            for lineSlice in remaining[index..<end] {
                let (chunkText, lineSpans) = JSONReformatter.reindentWithSpans(
                    lineSlice, utf16Offset: offset + formattedUTF16, expandNewlines: true
                )
                full += chunkText
                full += "\n\n"
                formattedUTF16 += chunkText.utf16.count + 2
                spans.append(contentsOf: lineSpans)
            }
            index = end
        }
        let ns = full as NSString
        var keywords = 0
        for span in spans {
            #expect(NSMaxRange(span.range) <= ns.length)
            if span.nodeTypeName == "xcode.syntax.keyword" {
                keywords += 1
                #expect(ns.substring(with: span.range) == "true")
            }
            if span.nodeTypeName == "xcode.syntax.string" {
                let covered = ns.substring(with: span.range)
                #expect(covered.hasPrefix("\""))
                #expect(covered.hasSuffix("\""))
            }
        }
        #expect(keywords == 950)
    }

    @MainActor
    @Test func setextHeadingLevelsRenderDistinctSizes() async throws {
        let doc = "TitleOne\n========\n\nTitleTwo\n--------\n\nbody text\n"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcql-setext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.md")
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
            if let one = pointSize(at: "TitleOne"), let body = pointSize(at: "body"), one > body { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let h1 = try #require(pointSize(at: "TitleOne"))
        let h2 = try #require(pointSize(at: "TitleTwo"))
        let body = try #require(pointSize(at: "body"))
        #expect(h1 > h2)
        #expect(h2 > body)
    }
}
