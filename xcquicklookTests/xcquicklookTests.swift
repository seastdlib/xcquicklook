import Foundation
import Testing
import UniformTypeIdentifiers

/// These tests run in a standalone (host-less, unsandboxed) bundle, so they
/// load the repo's copy of SourceModel.framework directly and read the
/// installed Xcode's color themes.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let repoFrameworkURL = repoRoot.appendingPathComponent("SourceModel.framework", isDirectory: true)

private let engine = HighlightEngine(frameworkURL: repoFrameworkURL)

/// A theme whose styled-type set matches Xcode's Default themes, independent
/// of whether Xcode is installed.
private let stubTheme = Theme(styles: [
    "xcode.syntax.comment": .init(color: .init(red: 0.36, green: 0.42, blue: 0.47, alpha: 1)),
    "xcode.syntax.keyword": .init(color: .init(red: 0.6, green: 0.13, blue: 0.57, alpha: 1), bold: true),
    "xcode.syntax.string": .init(color: .init(red: 0.77, green: 0.1, blue: 0.08, alpha: 1)),
    "xcode.syntax.character": .init(color: .init(red: 0.11, green: 0, blue: 0.81, alpha: 1)),
    "xcode.syntax.number": .init(color: .init(red: 0.11, green: 0, blue: 0.81, alpha: 1)),
    "xcode.syntax.url": .init(color: .init(red: 0.05, green: 0.05, blue: 1, alpha: 1)),
    "xcode.syntax.attribute": .init(color: .init(red: 0.5, green: 0.37, blue: 0.01, alpha: 1)),
    "xcode.syntax.preprocessor": .init(color: .init(red: 0.39, green: 0.22, blue: 0.12, alpha: 1)),
    "xcode.syntax.markup.delimiter": .init(color: .init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
])

private func spans(
    _ text: String,
    ext: String? = nil,
    uti: String? = nil,
    filename: String? = nil,
    conformsToSourceCode: Bool = false
) async throws -> [TokenSpan] {
    var hint = LanguageHint()
    if let uti {
        hint.contentTypeIdentifiers = [uti]
    } else if let ext, let type = UTType(filenameExtension: ext) {
        // Mirror production, which reads the file's content type from the URL.
        hint.contentTypeIdentifiers = [type.identifier]
    }
    hint.fileExtension = ext
    hint.filename = filename
    hint.firstLine = text.components(separatedBy: .newlines).first
    hint.conformsToSourceCode = conformsToSourceCode
    return try await engine.tokenize(text: text, hint: hint, theme: stubTheme)
}

/// True when some span of the given node type covers the first occurrence of `fragment`.
private func hasSpan(_ spans: [TokenSpan], type: String, covering fragment: String, in text: String) -> Bool {
    let target = (text as NSString).range(of: fragment)
    guard target.location != NSNotFound else { return false }
    return spans.contains { span in
        span.nodeTypeName == type && NSIntersectionRange(span.range, target).length == target.length
    }
}

struct EngineLoadingTests {
    @Test func loadsRepoFramework() async {
        #expect(await engine.isAvailable())
    }

    @Test func missingFrameworkFailsCleanly() async {
        let broken = HighlightEngine(frameworkURL: URL(fileURLWithPath: "/nonexistent/SourceModel.framework"))
        #expect(!(await broken.isAvailable()))
    }
}

struct ThemeTests {
    @Test func parsesInstalledDefaultThemes() async throws {
        for dark in [false, true] {
            let theme = try await engine.theme(dark: dark)
            let keyword = try #require(theme.style(forNodeTypeName: "xcode.syntax.keyword"))
            #expect(keyword.color != nil)
            #expect(keyword.bold)  // Default themes use SFMono-Semibold for keywords
            #expect(theme.style(forNodeTypeName: "xcode.syntax.string")?.color != nil)
            // Plain must stay unstyled so Quick Look's own text color wins.
            #expect(theme.style(forNodeTypeName: "xcode.syntax.plain") == nil)
        }
    }

    @Test func prefixFallbackResolvesSubtypes() {
        let theme = stubTheme
        #expect(theme.style(forNodeTypeName: "xcode.syntax.comment.doc.keyword") != nil)
        #expect(theme.style(forNodeTypeName: "xcode.syntax.nonexistent") == nil)
    }
}

struct DetectionTests {
    @Test func shebangParsing() {
        #expect(LanguageDetector.shebangLanguageID(firstLine: "#!/bin/sh") == "Xcode.SourceCodeLanguage.BourneShellScript")
        #expect(LanguageDetector.shebangLanguageID(firstLine: "#!/usr/bin/env python3") == "Xcode.SourceCodeLanguage.Python")
        #expect(LanguageDetector.shebangLanguageID(firstLine: "#!/usr/bin/env -S node --harmony") == "Xcode.SourceCodeLanguage.JavaScript")
        #expect(LanguageDetector.shebangLanguageID(firstLine: "plain first line") == nil)
    }

    @Test func aliasesAndFilenames() async throws {
        // TypeScript aliases onto the JavaScript spec.
        let ts = try await spans("const x = 42 // hi", ext: "ts")
        #expect(hasSpan(ts, type: "xcode.syntax.number", covering: "42", in: "const x = 42 // hi"))
        // Dockerfiles alias onto the shell spec by filename.
        let text = "# comment\nFROM alpine\n"
        let docker = try await spans(text, filename: "Dockerfile")
        #expect(hasSpan(docker, type: "xcode.syntax.comment", covering: "# comment", in: text))
    }

    @Test func extensionlessFilesClassifyByContent() async throws {
        // Dotfiles and bare symlink targets carry no extension or UTI identity;
        // structure decides. Shell rc files:
        let zprofile = "# path setup\nexport PATH=$PATH:/usr/local/bin\nalias ll='ls -la'\n"
        let result = try await spans(zprofile, uti: "public.data", filename: ".zprofile")
        #expect(hasSpan(result, type: "xcode.syntax.comment", covering: "# path setup", in: zprofile))

        let bare = "# aliases\nalias ll='ls -la'\nexport EDITOR=vim\n"
        let bareResult = try await spans(bare, uti: "public.data", filename: "zshrc")
        #expect(hasSpan(bareResult, type: "xcode.syntax.comment", covering: "# aliases", in: bare))

        // gitconfig-shaped content is INI.
        let gitconfig = "# identity\n[user]\n\tname = Example\n\temail = ex@example.org\n"
        let iniResult = try await spans(gitconfig, uti: "public.data", filename: ".gitconfig")
        #expect(hasSpan(iniResult, type: "xcode.syntax.comment", covering: "# identity", in: gitconfig))

        // Unclassifiable text still previews via the generic floor (no throw).
        let unknown = "just some words\nmore words 42\n"
        let floor = try await spans(unknown, uti: "public.data", filename: ".mystery")
        #expect(hasSpan(floor, type: "xcode.syntax.number", covering: "42", in: unknown))
    }

    @Test func extensionlessPlistsAndJSONDisambiguate() async throws {
        // XML plists look like XML and belong to the XML spec, as in Xcode.
        let xmlPlist = "<?xml version=\"1.0\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"x\">\n<plist version=\"1.0\"><dict><key>a</key><integer>1</integer></dict></plist>\n"
        let xmlResult = try await spans(xmlPlist, uti: "public.data", filename: "prefs")
        #expect(hasSpan(xmlResult, type: "xcode.syntax.keyword", covering: "<?", in: xmlPlist))

        // Old-style ASCII plists open with a brace like JSON but assign with
        // `key = value;` — they must go to the plist spec, not JSON.
        let asciiPlist = "{\n    \"name\" = \"xcql\";\n    \"count\" = \"3\";\n}\n"
        let asciiResult = try await spans(asciiPlist, uti: "public.data", filename: "settings")
        #expect(hasSpan(asciiResult, type: "xcode.syntax.string", covering: "\"xcql\"", in: asciiPlist))

        // Real JSON keeps JSON tokenization (true is a keyword there).
        let json = "{\"name\": \"xcql\", \"ok\": true}\n"
        let jsonResult = try await spans(json, uti: "public.data", filename: "config")
        #expect(hasSpan(jsonResult, type: "xcode.syntax.keyword", covering: "true", in: json))
    }

    @Test func jsonLinesAliasesToJSON() async throws {
        let text = "{\"k\": 42}\n{\"k\": 43}\n"
        let result = try await spans(text, ext: "jsonl")
        #expect(hasSpan(result, type: "xcode.syntax.number", covering: "42", in: text))
    }

    @Test func unknownWithoutFallbackThrows() async {
        await #expect(throws: HighlightEngine.EngineError.self) {
            _ = try await spans("some plain text", ext: "xyzunknown")
        }
    }

    @Test func genericSourceCodeFallback() async throws {
        let text = "token 42 more"
        let result = try await spans(text, ext: "xyzunknown", conformsToSourceCode: true)
        #expect(hasSpan(result, type: "xcode.syntax.number", covering: "42", in: text))
    }
}

struct TokenizationTests {
    @Test func swift() async throws {
        let text = "// note\nlet x = 42\nfunc f() -> String { \"a \\(x)\" }\n"
        let result = try await spans(text, ext: "swift")
        #expect(hasSpan(result, type: "xcode.syntax.comment", covering: "// note", in: text))
        #expect(hasSpan(result, type: "xcode.syntax.keyword", covering: "let", in: text))
        #expect(hasSpan(result, type: "xcode.syntax.number", covering: "42", in: text))
        // Interpolation inside the string literal must reset to plain.
        let interpolation = (text as NSString).range(of: "x)")
        #expect(result.contains { $0.nodeTypeName == nil && NSIntersectionRange($0.range, interpolation).length > 0 })
    }

    @Test func cFamily() async throws {
        for ext in ["c", "cpp", "m", "h"] {
            let text = "/* block */\nstatic int count = 3;\nchar *s = \"hi\";\n"
            let result = try await spans(text, ext: ext)
            #expect(hasSpan(result, type: "xcode.syntax.comment", covering: "/* block */", in: text), "\(ext)")
            #expect(hasSpan(result, type: "xcode.syntax.string", covering: "\"hi\"", in: text), "\(ext)")
        }
    }

    @Test func scripts() async throws {
        let sh = "#!/bin/sh\n# c\necho hello 42\n"
        let shResult = try await spans(sh, uti: "public.shell-script")
        #expect(hasSpan(shResult, type: "xcode.syntax.comment", covering: "# c", in: sh))

        let py = "# c\ndef f():\n    return \"x\"\n"
        let pyResult = try await spans(py, ext: "py")
        #expect(hasSpan(pyResult, type: "xcode.syntax.keyword", covering: "def", in: py))
        #expect(hasSpan(pyResult, type: "xcode.syntax.string", covering: "\"x\"", in: py))

        let rb = "# c\ndef f\n  \"s\"\nend\n"
        let rbResult = try await spans(rb, ext: "rb")
        #expect(hasSpan(rbResult, type: "xcode.syntax.keyword", covering: "def", in: rb))

        let pl = "# c\nmy $x = 42;\n"
        let plResult = try await spans(pl, ext: "pl")
        #expect(hasSpan(plResult, type: "xcode.syntax.comment", covering: "# c", in: pl))

        // Extensionless shebang script. Python single-quoted literals
        // tokenize as character constants in the Xcode spec.
        let bare = "#!/usr/bin/env python3\nx = 'str'\n"
        let bareResult = try await spans(bare)
        #expect(hasSpan(bareResult, type: "xcode.syntax.character", covering: "'str'", in: bare))
    }

    @Test func configFormats() async throws {
        let json = "{\"k\": 42}"
        let jsonResult = try await spans(json, uti: "public.json")
        #expect(hasSpan(jsonResult, type: "xcode.syntax.string", covering: "\"k\"", in: json))
        #expect(hasSpan(jsonResult, type: "xcode.syntax.number", covering: "42", in: json))

        let yaml = "k: v # c\nn: 42\n"
        let yamlResult = try await spans(yaml, uti: "public.yaml")
        #expect(hasSpan(yamlResult, type: "xcode.syntax.comment", covering: "# c", in: yaml))

        let toml = "# c\n[sec]\nk = 42\n"
        let tomlResult = try await spans(toml, ext: "toml")
        #expect(hasSpan(tomlResult, type: "xcode.syntax.comment", covering: "# c", in: toml))

        let plist = "<?xml version=\"1.0\"?><plist><dict><key>a</key></dict></plist>"
        let plistResult = try await spans(plist, uti: "com.apple.xml-property-list")
        #expect(!plistResult.isEmpty)

        let xcconfig = "// c\nSDKROOT = macosx\n"
        let xcconfigResult = try await spans(xcconfig, ext: "xcconfig")
        #expect(hasSpan(xcconfigResult, type: "xcode.syntax.comment", covering: "// c", in: xcconfig))
    }

    @Test func webFormats() async throws {
        let js = "// c\nconst s = \"x\";\n"
        let jsResult = try await spans(js, ext: "js")
        #expect(hasSpan(jsResult, type: "xcode.syntax.string", covering: "\"x\"", in: js))

        let css = "/* c */ body { color: red; }"
        let cssResult = try await spans(css, ext: "css")
        #expect(hasSpan(cssResult, type: "xcode.syntax.comment", covering: "/* c */", in: css))

        let xml = "<a b=\"1\"><!-- c --></a>"
        let xmlResult = try await spans(xml, uti: "public.xml")
        #expect(hasSpan(xmlResult, type: "xcode.syntax.comment", covering: "<!-- c -->", in: xml))

        let md = "# Title\n[l](https://a.b)\n"
        let mdResult = try await spans(md, uti: "net.daringfireball.markdown")
        #expect(hasSpan(mdResult, type: "xcode.syntax.url", covering: "https://a.b", in: md))
    }

    @Test func spansAreOrderedAndBounded() async throws {
        let text = "let s = \"a \\(1 + 2) b\"\n"
        let result = try await spans(text, ext: "swift")
        let length = (text as NSString).length
        for span in result {
            #expect(span.range.location >= 0)
            #expect(NSMaxRange(span.range) <= length)
        }
    }
}
