import AppKit
import Foundation
import Testing

/// Cycle 1: encoding ladder hardening plus adversarial detection cases.
@MainActor
struct EncodingLadderTests {
    private let text = "let café = 1 // done\n"

    @Test func bomlessUTF16BothEndians() {
        let le = text.data(using: .utf16LittleEndian)!
        let be = text.data(using: .utf16BigEndian)!
        #expect(PreviewViewController.decodeText(le) == text)
        #expect(PreviewViewController.decodeText(be) == text)
    }

    @Test func utf32WithBOM() {
        var le = Data([0xFF, 0xFE, 0x00, 0x00])
        le.append(text.data(using: .utf32LittleEndian)!)
        #expect(PreviewViewController.decodeText(le) == text)

        var be = Data([0x00, 0x00, 0xFE, 0xFF])
        be.append(text.data(using: .utf32BigEndian)!)
        #expect(PreviewViewController.decodeText(be) == text)
    }

    @Test func bomsAreStrippedNotRendered() {
        var utf8BOM = Data([0xEF, 0xBB, 0xBF])
        utf8BOM.append(text.data(using: .utf8)!)
        #expect(PreviewViewController.decodeText(utf8BOM) == text)

        var utf16BOM = Data([0xFF, 0xFE])
        utf16BOM.append(text.data(using: .utf16LittleEndian)!)
        let decoded = PreviewViewController.decodeText(utf16BOM)
        #expect(decoded == text)
        #expect(decoded?.unicodeScalars.first != "\u{FEFF}")
    }

    @Test func utf16LEWhoseFirstCharacterIsNULIsNotMistakenForUTF32() {
        // "\0a" in UTF-16LE starts FF FE 00 00 ... only if BOM'd and first
        // char is NUL; length not divisible by 4 must fall back to UTF-16.
        var data = Data([0xFF, 0xFE])
        data.append("\u{0000}abc".data(using: .utf16LittleEndian)!)
        let decoded = PreviewViewController.decodeText(data)
        #expect(decoded?.contains("abc") == true)
    }

    @Test func binaryStillDeclines() {
        // Mach-O-ish: NULs scattered on both parities.
        #expect(PreviewViewController.decodeText(Data([0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00, 0x01, 0x00, 0x00, 0x02, 0x00, 0x03])) == nil)
        // PNG signature followed by compressed noise (no NUL parity skew).
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        for i in 0..<64 { png.append(UInt8((i % 3 == 0) ? 0 : (37 + i))) }
        #expect(PreviewViewController.decodeText(png) == nil)
    }

    @Test func evenLengthASCIINeverBecomesMojibake() {
        let ascii = "name = value\n[core]\n\n\n"
        #expect(PreviewViewController.decodeText(ascii.data(using: .ascii)!) == ascii)
    }

    @Test func latin1AndEmptyAndTiny() {
        #expect(PreviewViewController.decodeText(text.data(using: .isoLatin1)!)?.contains("café") == true)
        #expect(PreviewViewController.decodeText(Data()) == "")
        #expect(PreviewViewController.decodeText(Data([0x41])) == "A")
    }

    @Test func carriageReturnOnlyLineEndings() async throws {
        // Classic Mac line endings: shebang parsing and tokenization survive.
        let cr = "#!/bin/sh\r# note\recho hi 42\r"
        let result = try await spans(cr, uti: "public.data", filename: "script")
        #expect(!result.isEmpty)
        checkSpansInBounds(result, textLength: (cr as NSString).length)
    }
}

private func checkSpansInBounds(_ result: [TokenSpan], textLength: Int) {
    for span in result {
        #expect(span.range.location >= 0)
        #expect(NSMaxRange(span.range) <= textLength)
    }
}

struct AdversarialDetectionTests {
    @Test func yamlDocumentStartMarker() async throws {
        let yaml = "---\nname: xcql\ncount: 42\n"
        let result = try await spans(yaml, uti: "public.data", filename: "config")
        #expect(hasSpan(result, type: "xcode.syntax.number", covering: "42", in: yaml))
    }

    @Test func extensionlessCFileViaPreprocessorDirectives() async throws {
        let c = "#include <stdio.h>\nint main(void) { return 42; }\n"
        let result = try await spans(c, uti: "public.data", filename: "conftest")
        #expect(hasSpan(result, type: "xcode.syntax.preprocessor", covering: "#include", in: c))
    }

    @Test func plainTxtWithShellContentStaysUnhighlighted() async throws {
        // Extensions always outrank content: a .txt is plain, whatever it holds.
        let shell = "#comment\nexport A=1\nalias b=c\nsetopt X\n"
        let result = try? await spans(shell, ext: "txt", uti: "public.plain-text")
        // Either the framework's hidden Plain language (no colored spans for
        // this content) or a clean noLanguage throw — never shell coloring.
        if let result {
            #expect(!hasSpan(result, type: "xcode.syntax.comment", covering: "#comment", in: shell))
        }
    }

    @Test func extensionOutranksConflictingShebang() async throws {
        // A .py file with a shell shebang is still Python (UTI/extension first).
        let text = "#!/bin/sh\ndef f():\n    return \"x\"\n"
        let result = try await spans(text, ext: "py")
        #expect(hasSpan(result, type: "xcode.syntax.keyword", covering: "def", in: text))
    }

    @Test func uppercaseExtensions() async throws {
        let swift = "// c\nlet x = 42\n"
        let result = try await spans(swift, ext: "SWIFT")
        #expect(hasSpan(result, type: "xcode.syntax.keyword", covering: "let", in: swift))
    }

    @Test func whitespaceOnlyAndMarkdownishFallToFloorWithoutThrowing() async throws {
        for content in ["   \n\t\n  \n", "# Title\n\nProse words here.\n"] {
            _ = try await spans(content, uti: "public.data", filename: "notes")
        }
    }

    @Test func noTrailingNewlineAndMidFileBOM() async throws {
        let text = "let x = 1 // end\u{FEFF}marker"
        let result = try await spans(text, ext: "swift")
        checkSpansInBounds(result, textLength: (text as NSString).length)
    }

    @Test func deepNestingDoesNotCrash() async throws {
        let depth = 2000
        let json = String(repeating: "[", count: depth) + "42" + String(repeating: "]", count: depth)
        let result = try await spans(json, uti: "public.json")
        checkSpansInBounds(result, textLength: (json as NSString).length)
    }
}
