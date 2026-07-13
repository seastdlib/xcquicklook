import Foundation
import Testing

/// Regressions for the six failures found by the adversary agent (round 2).
struct RedTeamRegressionTests {
    @Test func crlfINIStillClassifiesAsINI() async throws {
        let ini = "# identity\r\n[user]\r\n\tname = Example\r\n\temail = ex@example.org\r\n"
        let result = try await spans(ini, uti: "public.data", filename: ".gitconfig")
        #expect(hasSpan(result, type: "xcode.syntax.comment", covering: "# identity", in: ini))
    }

    @Test func markdownFrontMatterDoesNotBecomeYAML() async throws {
        let doc = """
        ---
        title: Release notes
        date: 2026-07-12
        tags: draft
        ---
        # Real Markdown Heading

        Body text with [a link](https://example.org).
        """
        let result = try await spans(doc, uti: "public.data", filename: "README")
        // Under the markdown spec, the heading is markup, never a comment.
        #expect(!hasSpan(result, type: "xcode.syntax.comment", covering: "# Real Markdown Heading", in: doc))
        #expect(hasSpan(result, type: "xcode.syntax.url", covering: "https://example.org", in: doc))
    }

    @Test func envLocalHighlightsLikeEnv() async throws {
        let env = "# secrets\nexport API_KEY=abc123\nexport DB_URL=\"postgres://x\"\n"
        let result = try await spans(env, ext: "local", uti: "dyn.ah62d4rv4ge8027pb", filename: ".env.local")
        #expect(hasSpan(result, type: "xcode.syntax.comment", covering: "# secrets", in: env))
        #expect(hasSpan(result, type: "xcode.syntax.keyword", covering: "export", in: env))
    }

    @Test func shellFunctionDefinitionsClassifyAsShell() async throws {
        let script = """
        path_prepend() {
          PATH="$1:$PATH"
        }
        path_prepend /usr/local/bin
        PS1='$ '
        """
        let result = try await spans(script, uti: "public.data", filename: ".profile")
        #expect(!result.isEmpty)
        // Shell spec colors the $1 parameter expansion inside the string.
        #expect(hasSpan(result, type: "xcode.syntax.string", covering: "\"$1:$PATH\"", in: script)
            || hasSpan(result, type: "xcode.syntax.identifier", covering: "PATH", in: script))
    }

    @Test func longCommentHeaderDoesNotExhaustVoteWindow() async throws {
        var text = ""
        for i in 0..<80 { text += "# header comment line \(i)\n" }
        text += "export EDITOR=vim\nalias ll='ls -la'\nexport LANG=en_US.UTF-8\nsetopt AUTO_CD\n"
        let result = try await spans(text, uti: "public.data", filename: ".zshrc")
        #expect(hasSpan(result, type: "xcode.syntax.keyword", covering: "export", in: text))
    }

    @MainActor
    @Test func bomOnlyFileIsEmptyNotMojibake() {
        for bom: [UInt8] in [[0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF]] {
            let decoded = PreviewViewController.decodeText(Data(bom))
            #expect(decoded == "" || decoded == nil, "BOM \(bom)")
            #expect(decoded?.contains("\u{FFFD}") != true, "BOM \(bom) produced replacement char")
        }
    }
}

/// Regressions for the eight failures found by the adversary agent (round 3).
struct RedTeam3RegressionTests {
    @MainActor
    @Test func latin1SparseAccentsSurviveLossyDetection() {
        // Mostly-ASCII Latin-1: lossy detection would pick UTF-8 and replace
        // every accent with U+FFFD.
        let text = "nom = café\n" + String(repeating: "x = 1\n", count: 100)
        let decoded = PreviewViewController.decodeText(text.data(using: .isoLatin1)!)
        #expect(decoded?.contains("café") == true)
        #expect(decoded?.contains("\u{FFFD}") != true)
    }

    @MainActor
    @Test func asciiHeadWithBinaryNULTailDeclines() {
        var data = Data(String(repeating: "log line: everything is fine\n", count: 300).utf8)
        data.append(Data(count: 4096))
        #expect(PreviewViewController.decodeText(data) == nil)
    }

    @Test func gitconfigWithShellFlavoredAliasValuesStaysINI() {
        let text = "# aliases\n[alias]\n\tlg = log --pretty=\"$FMT\"\n\twho = shortlog --since=\"$SINCE\"\n\tst = status\n[core]\n\tpager = less -FRX"
        #expect(LanguageDetector.contentLanguageID(forTextPrefix: text) == "Xcode.SourceCodeLanguage.TOML_INI")
    }

    @Test func actionsStyleYAMLWithQuotedVarsDoesNotBecomeShell() {
        let text = "name: CI\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo \"$GITHUB_SHA\"\n      - run: git describe \"$GITHUB_REF\""
        #expect(LanguageDetector.contentLanguageID(forTextPrefix: text) != "Xcode.SourceCodeLanguage.BourneShellScript")
    }

    @Test func gitconfigOpeningWithSectionHeaderIsNotJSON() {
        let text = "[user]\n\tname = Example\n[core]\n\tpager = less -FRX"
        #expect(LanguageDetector.contentLanguageID(forTextPrefix: text) == "Xcode.SourceCodeLanguage.TOML_INI")
    }

    @Test func swiftLikeSourceDoesNotClassifyAsShell() {
        let text = "import Foundation\n\nfunc main() {\n    print(\"hi\")\n}\n\nstruct Config {\n    func load() {\n    }\n}"
        #expect(LanguageDetector.contentLanguageID(forTextPrefix: text) != "Xcode.SourceCodeLanguage.BourneShellScript")
    }

    @Test func configureStyleHeredocStaysShellDespiteDefines() {
        let text = "cat > confdefs.h <<EOF\n#define PACKAGE \"demo\"\n#define VERSION \"1.0\"\nEOF\necho done"
        #expect(LanguageDetector.contentLanguageID(forTextPrefix: text) == "Xcode.SourceCodeLanguage.BourneShellScript")
    }

    @Test func themeRejectsNonFiniteAndJunkColors() throws {
        let plist: [String: Any] = [
            "DVTSourceTextSyntaxColors": [
                "xcode.syntax.keyword": "nan nan nan nan",
                "xcode.syntax.string": "inf -inf 1e999 1",
                "xcode.syntax.comment": "0.1 0.2 0.3 1 extra",
                "xcode.syntax.number": "0.1 0.2 0.3 1",
            ],
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).xccolortheme")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        let theme = try Theme.load(from: url)
        #expect(theme.style(forNodeTypeName: "xcode.syntax.keyword")?.color == nil)
        #expect(theme.style(forNodeTypeName: "xcode.syntax.string")?.color == nil)
        #expect(theme.style(forNodeTypeName: "xcode.syntax.comment")?.color == nil)
        #expect(theme.style(forNodeTypeName: "xcode.syntax.number")?.color != nil)
    }

    @Test func proseFileNamedSwiftIsNotTokenizedAsSwift() async throws {
        let prose = "let us go then, you and I\nas the evening spreads\nif only for a while\n"
        let result = try await spans(prose, uti: "public.data", filename: "swift")
        #expect(!hasSpan(result, type: "xcode.syntax.keyword", covering: "let", in: prose))
    }
}
