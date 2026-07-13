import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

// MARK: - Fixture corpus

private let fixturesDir = repoRoot.appendingPathComponent("xcquicklookTests/Fixtures", isDirectory: true)

private func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: fixturesDir.appendingPathComponent(name), encoding: .utf8)
}

/// One corpus entry: how the file presents itself to detection, and fragments
/// that must be covered by a span of the given node type.
private struct CorpusCase: Sendable {
    var fixture: String
    var ext: String?
    var uti: String?
    var filename: String?
    var expected: [(type: String, fragment: String)]
}

private let corpus: [CorpusCase] = [
    .init(fixture: "sample.swift", ext: "swift", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "// greeting"),
        ("xcode.syntax.keyword", "func"),
        ("xcode.syntax.number", "42"),
        ("xcode.syntax.string", "\"hey "),
    ]),
    .init(fixture: "sample.c", ext: "c", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "/* block */"),
        ("xcode.syntax.string", "\"hi "),
        ("xcode.syntax.number", "3"),
    ]),
    .init(fixture: "sample.cpp", ext: "cpp", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "// cpp"),
        ("xcode.syntax.number", "7"),
    ]),
    .init(fixture: "sample.m", ext: "m", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "// objc"),
        ("xcode.syntax.number", "42"),
    ]),
    .init(fixture: "sample.py", ext: "py", uti: nil, filename: nil, expected: [
        ("xcode.syntax.keyword", "def"),
        ("xcode.syntax.string", "\"value\""),
    ]),
    .init(fixture: "sample.rb", ext: "rb", uti: nil, filename: nil, expected: [
        ("xcode.syntax.keyword", "def"),
        ("xcode.syntax.string", "\"str\""),
    ]),
    .init(fixture: "sample.pl", ext: "pl", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "# comment"),
        ("xcode.syntax.number", "42"),
    ]),
    .init(fixture: "sample.sh", ext: "sh", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "# setup"),
        ("xcode.syntax.number", "42"),
    ]),
    .init(fixture: "sample.js", ext: "js", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "// js"),
        ("xcode.syntax.string", "\"hello\""),
    ]),
    .init(fixture: "sample.css", ext: "css", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "/* styles */"),
    ]),
    .init(fixture: "sample.xml", ext: nil, uti: "public.xml", filename: nil, expected: [
        ("xcode.syntax.comment", "<!-- doc -->"),
        ("xcode.syntax.string", "\"value\""),
    ]),
    .init(fixture: "sample.json", ext: nil, uti: "public.json", filename: nil, expected: [
        ("xcode.syntax.string", "\"name\""),
        ("xcode.syntax.number", "42"),
        ("xcode.syntax.keyword", "true"),
    ]),
    .init(fixture: "sample.yaml", ext: nil, uti: "public.yaml", filename: nil, expected: [
        ("xcode.syntax.comment", "# config"),
        ("xcode.syntax.number", "42"),
    ]),
    .init(fixture: "sample.toml", ext: "toml", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "# settings"),
        ("xcode.syntax.number", "8080"),
        ("xcode.syntax.string", "\"localhost\""),
    ]),
    .init(fixture: "sample.md", ext: nil, uti: "net.daringfireball.markdown", filename: nil, expected: [
        ("xcode.syntax.url", "https://example.org"),
    ]),
    .init(fixture: "sample.xcconfig", ext: "xcconfig", uti: nil, filename: nil, expected: [
        ("xcode.syntax.comment", "// build settings"),
    ]),
    .init(fixture: "sample.plist", ext: nil, uti: "com.apple.xml-property-list", filename: nil, expected: [
        ("xcode.syntax.keyword", "<?"),
    ]),
    .init(fixture: "zshrc", ext: nil, uti: "public.data", filename: "zshrc", expected: [
        ("xcode.syntax.comment", "# aliases and exports"),
    ]),
    .init(fixture: "gitconfig", ext: nil, uti: "public.data", filename: "gitconfig", expected: [
        ("xcode.syntax.comment", "# identity"),
    ]),
    .init(fixture: "minified.js", ext: "js", uti: nil, filename: nil, expected: [
        ("xcode.syntax.string", "\"s0\""),
        ("xcode.syntax.string", "\"s299\""),
    ]),
]

struct CorpusTests {
    @Test func allFixturesTokenizeWithExpectedSpans() async throws {
        for entry in corpus {
            let text = try fixtureText(entry.fixture)
            let result = try await spans(
                text, ext: entry.ext, uti: entry.uti, filename: entry.filename
            )
            #expect(!result.isEmpty, "\(entry.fixture): no spans")
            for (type, fragment) in entry.expected {
                #expect(
                    hasSpan(result, type: type, covering: fragment, in: text),
                    "\(entry.fixture): expected \(type) covering \(fragment)"
                )
            }
        }
    }
}

// MARK: - Properties

/// Deterministic generator so failures reproduce.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func checkInvariants(_ result: [TokenSpan], textLength: Int, label: String) {
    for span in result {
        #expect(span.range.location >= 0, "\(label): negative location")
        #expect(NSMaxRange(span.range) <= textLength, "\(label): span out of bounds")
    }
    // Pre-order emission: any two overlapping spans must be ancestor/descendant,
    // with the ancestor first.
    for i in result.indices {
        for j in result.indices where j > i {
            let a = result[i].range
            let b = result[j].range
            let overlap = NSIntersectionRange(a, b).length > 0
            if overlap {
                let contains = a.location <= b.location && NSMaxRange(a) >= NSMaxRange(b)
                #expect(contains, "\(label): spans \(i),\(j) overlap without containment")
            }
        }
    }
    // Resets only appear inside an earlier styled span.
    for i in result.indices where result[i].nodeTypeName == nil {
        let reset = result[i].range
        let hasStyledAncestor = result[..<i].contains { earlier in
            earlier.nodeTypeName != nil
                && earlier.range.location <= reset.location
                && NSMaxRange(earlier.range) >= NSMaxRange(reset)
        }
        #expect(hasStyledAncestor, "\(label): reset span without styled ancestor")
    }
}

struct PropertyTests {
    @Test func corpusFixturesSatisfyInvariants() async throws {
        for entry in corpus {
            let text = try fixtureText(entry.fixture)
            let result = try await spans(text, ext: entry.ext, uti: entry.uti, filename: entry.filename)
            checkInvariants(result, textLength: (text as NSString).length, label: entry.fixture)
        }
    }

    @Test func garbageInputNeverCrashesOrEscapesBounds() async throws {
        var rng = SeededGenerator(state: 0x5EED)
        let alphabets: [[Character]] = [
            Array("abc {}()[]\"'\\/#=:;,.\n\t $%&*<>!-"),
            Array("日本語テキスト🎉👨‍👩‍👧‍👦\u{301}\u{FEFF}αβγ\n\"'{}"),
        ]
        for iteration in 0..<24 {
            let alphabet = alphabets[iteration % alphabets.count]
            let length = 200 + Int(rng.next() % 1800)
            let text = String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            for ext in ["swift", "sh", "js"] {
                let result = try await spans(text, ext: ext)
                checkInvariants(result, textLength: (text as NSString).length, label: "garbage-\(iteration)-\(ext)")
            }
            // Extensionless garbage goes through the classifier + generic floor.
            let floorResult = try await spans(text, uti: "public.data", filename: "noise")
            checkInvariants(floorResult, textLength: (text as NSString).length, label: "garbage-floor-\(iteration)")
        }
    }
}

// MARK: - Controller (readText + live highlight application)

@MainActor
struct ControllerTests {
    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcql-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @Test func readTextHandlesEncodings() throws {
        let plain = "let café = 1\n"
        func read(_ data: Data) throws -> String? {
            PreviewViewController.readText(at: try tempFile("f.swift", data))
        }

        #expect(try read(plain.data(using: .utf8)!)?.contains("café") == true)

        var utf8BOM = Data([0xEF, 0xBB, 0xBF])
        utf8BOM.append(plain.data(using: .utf8)!)
        #expect(try read(utf8BOM)?.contains("café") == true)

        #expect(try read(plain.data(using: .utf16LittleEndian)! .withBOM([0xFF, 0xFE]))?.contains("café") == true)
        #expect(try read(plain.data(using: .utf16BigEndian)!.withBOM([0xFE, 0xFF]))?.contains("café") == true)

        // Latin-1 (no BOM, invalid as UTF-8) must fall back, not decline.
        #expect(try read(plain.data(using: .isoLatin1)!)?.contains("café") == true)

        // Even-length ASCII must never be misread as UTF-16 (CJK mojibake).
        let ascii = "name = value\n[core]\n\n\n"
        let decoded = try read(ascii.data(using: .ascii)!)
        #expect(decoded == ascii)

        // NUL-laden data without a BOM is binary: decline.
        #expect(try read(Data([0x4D, 0x5A, 0x00, 0x00, 0x01, 0x02])) == nil)
    }

    /// Polls until the given fragment's foreground color differs from textColor.
    private func waitForHighlight(in controller: PreviewViewController, fragment: String, timeout: TimeInterval = 8) async -> NSColor? {
        func findTextView(in view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
            return nil
        }
        guard let storage = findTextView(in: controller.view)?.textStorage else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ns = storage.string as NSString
            let range = ns.range(of: fragment)
            if range.location != NSNotFound, storage.length > range.location {
                let attrs = storage.attributes(at: range.location, effectiveRange: nil)
                if let color = attrs[.foregroundColor] as? NSColor, color != NSColor.textColor {
                    return color
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    @Test func prepareShowsTextInstantlyThenHighlights() async throws {
        let source = "// note\nlet x = 42\n"
        let url = try tempFile("live.swift", source.data(using: .utf8)!)
        let controller = PreviewViewController()
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        try await controller.preparePreviewOfFile(at: url)

        func findTextView(in view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
            return nil
        }
        // Text is present the moment prepare returns.
        #expect(findTextView(in: controller.view)?.string == source)
        // Colors arrive asynchronously.
        #expect(await waitForHighlight(in: controller, fragment: "let") != nil)
    }

    @Test func controllerReuseShowsSecondFileWithoutStaleState() async throws {
        let first = "// first\nlet a = 1\n"
        let second = "# second\nvalue: 42\nother: text\nmore: lines\n"
        let controller = PreviewViewController()
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        try await controller.preparePreviewOfFile(at: tempFile("a.swift", first.data(using: .utf8)!))
        // Immediately reuse for a different file, as Quick Look does.
        try await controller.preparePreviewOfFile(at: tempFile("b.yaml", second.data(using: .utf8)!))

        func findTextView(in view: NSView) -> NSTextView? {
            if let tv = view as? NSTextView { return tv }
            for sub in view.subviews { if let tv = findTextView(in: sub) { return tv } }
            return nil
        }
        #expect(findTextView(in: controller.view)?.string == second)
        #expect(await waitForHighlight(in: controller, fragment: "# second") != nil)
    }
}

private extension Data {
    func withBOM(_ bom: [UInt8]) -> Data {
        var data = Data(bom)
        data.append(self)
        return data
    }
}

// MARK: - Performance budgets

struct BenchmarkTests {
    @Test func tokenizePerformanceBudgets() async throws {
        // Dedicated engine: other suites run in parallel and funnel through
        // the shared module-level engine actor; measuring against that queue
        // would time contention, not tokenization.
        let benchEngine = HighlightEngine(frameworkURL: repoFrameworkURL)
        // Generous ceilings: these catch order-of-magnitude regressions, not noise.
        var swiftSource = ""
        for i in 0..<1500 {
            swiftSource += "// comment line \(i)\nfunc f\(i)(a: Int) -> String { return \"v \\(a)\" }\nlet g\(i) = 3.14\n"
        }
        let budgets: [(label: String, text: String, ext: String, seconds: Double)] = [
            ("swift-127KB", swiftSource, "swift", 3.0),
            ("minified-js", try fixtureText("minified.js"), "js", 3.0),
        ]
        for budget in budgets {
            var hint = LanguageHint()
            hint.fileExtension = budget.ext
            if let type = UTType(filenameExtension: budget.ext) {
                hint.contentTypeIdentifiers = [type.identifier]
            }
            let start = ContinuousClock.now
            let result = try await benchEngine.tokenize(text: budget.text, hint: hint, theme: stubTheme)
            let elapsed = ContinuousClock.now - start
            #expect(!result.isEmpty, "\(budget.label): no spans")
            #expect(elapsed < .seconds(budget.seconds), "\(budget.label) took \(elapsed)")
        }
    }
}
