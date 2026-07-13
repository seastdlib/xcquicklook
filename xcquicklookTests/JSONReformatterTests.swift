import AppKit
import Foundation
import Testing

struct JSONReformatterTests {
    @Test func reindentsMinifiedObject() {
        let out = JSONReformatter.reindent("{\"a\":1,\"b\":[true,null],\"c\":{}}"[...])
        let expected = """
        {
          "a": 1,
          "b": [
            true,
            null
          ],
          "c": {}
        }
        """
        #expect(out == expected)
    }

    @Test func preservesBytesInsideStrings() {
        // Braces, colons, commas, escapes (except \n, which deliberately
        // becomes a real break), and unicode inside strings pass through
        // untouched.
        let input = "{\"msg\":\"a{b}[c],d:e \\\" \\\\ 日本語 🎉\",\"n\":1.2500e-3}"
        let out = JSONReformatter.reindent(input[...])
        #expect(out.contains("\"a{b}[c],d:e \\\" \\\\ 日本語 🎉\""))
        #expect(out.contains("1.2500e-3"))
    }

    @Test func stableUnderReapplication() {
        let once = JSONReformatter.reindent("{\"a\":[1,2,{\"b\":\"x\"}]}"[...])
        let twice = JSONReformatter.reindent(once[...])
        #expect(once == twice)
    }

    @Test func invalidInputDegradesWithoutCrashing() {
        for junk in ["{\"unterminated", "}}}}", "{\"a\":1", "", "not json at all"] {
            _ = JSONReformatter.reindent(junk[...])
        }
    }

    @Test func jobSplitsHeadAndRemainder() {
        // Many long lines: head formatted, remainder deferred.
        let line = "{\"role\":\"assistant\",\"content\":\"" + String(repeating: "x", count: 600) + "\"}"
        let text = Array(repeating: line, count: 500).joined(separator: "\n")
        let job = JSONReformatter.job(for: text)
        let (initial, initialSpans, remaining) = try! #require(job)
        #expect(initial.contains("\"role\": \"assistant\""))
        #expect(!initialSpans.isEmpty)
        #expect(!remaining.isEmpty)
        // Span coordinates are valid within the head text.
        let ns = initial as NSString
        for span in initialSpans {
            #expect(NSMaxRange(span.range) <= ns.length)
        }
        // Already-pretty JSON is left alone.
        #expect(JSONReformatter.job(for: initial) == nil)
        // Non-JSON text is left alone.
        #expect(JSONReformatter.job(for: "plain text\nlines here\n") == nil)
    }

    @Test func escapedNewlinesBecomeAlignedLineBreaks() {
        let input = "{\"content\":\"first line\\nsecond line\\nthird\"}"
        // Expansion is opt-in (jsonl only); default keeps escapes intact.
        let defaultOut = JSONReformatter.reindent(input[...])
        #expect(defaultOut.contains("first line\\nsecond line"))
        let (text, spans) = JSONReformatter.reindentWithSpans(input[...], utf16Offset: 0, expandNewlines: true)
        // Real line breaks, continuation aligned to the string's start column.
        let lines = text.components(separatedBy: "\n")
        let firstIndex = try! #require(lines.firstIndex(where: { $0.contains("first line") }))
        let opening = lines[firstIndex]
        let column = (opening as NSString).range(of: "\"first").location + 1
        #expect(lines[firstIndex + 1] == String(repeating: " ", count: column) + "second line")
        #expect(lines[firstIndex + 2] == String(repeating: " ", count: column) + "third\"")
        // The whole logical string — breaks and indents included — is ONE
        // string span, so highlighting covers every continuation line.
        let stringSpans = spans.filter { $0.nodeTypeName == "xcode.syntax.string" }
        let value = try! #require(stringSpans.last)
        let covered = (text as NSString).substring(with: value.range)
        #expect(covered.hasPrefix("\"first line\n"))
        #expect(covered.hasSuffix("third\""))
        // Escaped backslash-n (\\n in source, i.e. literal backslash + n)
        // must NOT break: it is content, not a newline escape.
        let literal = "{\"path\":\"a\\\\nb\"}"
        let (text2, _) = JSONReformatter.reindentWithSpans(literal[...], utf16Offset: 0, expandNewlines: true)
        #expect(text2.contains("a\\\\nb"))
    }

    @Test func spanOffsetsAreUTF16CorrectWithAstralContent() {
        let input = "{\"emoji\":\"🎉🎉\",\"n\":42,\"ok\":true}"
        let (text, spans) = JSONReformatter.reindentWithSpans(input[...], utf16Offset: 0)
        let ns = text as NSString
        for span in spans {
            #expect(NSMaxRange(span.range) <= ns.length)
        }
        let number = try! #require(spans.first(where: { $0.nodeTypeName == "xcode.syntax.number" }))
        #expect(ns.substring(with: number.range) == "42")
        let keyword = try! #require(spans.first(where: { $0.nodeTypeName == "xcode.syntax.keyword" }))
        #expect(ns.substring(with: keyword.range) == "true")
    }

    @Test func bareMinusIsNotANumberSpan() {
        let (text, spans) = JSONReformatter.reindentWithSpans("{\"k\":-,\"n\":-5}"[...], utf16Offset: 0)
        let ns = text as NSString
        let numbers = spans.filter { $0.nodeTypeName == "xcode.syntax.number" }
        #expect(numbers.count == 1)
        #expect(ns.substring(with: numbers[0].range) == "-5")
    }

    @Test func reindentThroughputSupportsStreaming() {
        // The synchronous head is ~128KB; budget far above any viewport need.
        let line = "{\"k\":\"" + String(repeating: "v", count: 500) + "\",\"n\":[1,2,3]}"
        let lines = Array(repeating: line[...], count: 4000)  // ~2MB
        let start = ContinuousClock.now
        var total = 0
        for l in lines { total += JSONReformatter.reindent(l).utf8.count }
        let elapsed = ContinuousClock.now - start
        #expect(total > 0)
        #expect(elapsed < .seconds(2), "2MB reindent took \(elapsed)")
    }
}

@MainActor
struct JSONPreviewTests {
    @Test func transcriptStyleJSONLIsInstantlyReadableAndStreamsFully() async throws {
        let object = "{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"" + String(repeating: "words ", count: 200) + "\"}"
        let doc = Array(repeating: object, count: 300).joined(separator: "\n")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcql-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.jsonl")
        try doc.data(using: .utf8)!.write(to: url)

        let controller = PreviewViewController()
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        try await controller.preparePreviewOfFile(at: url)

        func findTextView(in view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
            return nil
        }
        let storage = try #require(findTextView(in: controller.view)?.textStorage)

        // The instant guarantee: the moment prepare returns, the visible head
        // is already pretty-printed, not a minified wall.
        let head = (storage.string as NSString).substring(to: min(200, storage.length))
        #expect(head.contains("\"type\": \"message\""))
        #expect(head.contains("\n"))

        // Streaming completes: all 300 objects arrive, formatted.
        let deadline = Date().addingTimeInterval(10)
        var settled = 0
        while Date() < deadline {
            let count = storage.string.components(separatedBy: "\"type\": \"message\"").count - 1
            if count == 300 { settled = count; break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(settled == 300)
    }
}
