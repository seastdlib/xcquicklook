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
