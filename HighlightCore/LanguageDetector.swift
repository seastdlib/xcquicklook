import Foundation

/// Everything needed to pick a language for a file, computed by the caller
/// (which has the URL and content) and consumed inside the highlight actor.
nonisolated struct LanguageHint: Sendable {
    /// The file's content type identifier(s), most specific first.
    var contentTypeIdentifiers: [String] = []
    /// Whether the content type conforms to public.source-code (generic fallback).
    var conformsToSourceCode: Bool = false
    var fileExtension: String?
    var filename: String?
    /// The first line of the file, for shebang detection.
    var firstLine: String?
}

/// Static tables mapping files that Xcode itself doesn't claim onto the
/// closest available language specification.
nonisolated enum LanguageDetector {

    /// File extension (lowercased) → Xcode.SourceCodeLanguage identifier.
    static let aliasLanguageIDs: [String: String] = [
        // JavaScript relatives
        "ts": "Xcode.SourceCodeLanguage.JavaScript",
        "tsx": "Xcode.SourceCodeLanguage.JavaScript",
        "jsx": "Xcode.SourceCodeLanguage.JavaScript",
        "mjs": "Xcode.SourceCodeLanguage.JavaScript",
        "cjs": "Xcode.SourceCodeLanguage.JavaScript",
        // Shell relatives
        "zsh": "Xcode.SourceCodeLanguage.BourneShellScript",
        "bash": "Xcode.SourceCodeLanguage.BourneShellScript",
        "ksh": "Xcode.SourceCodeLanguage.BourneShellScript",
        "dash": "Xcode.SourceCodeLanguage.BourneShellScript",
        "fish": "Xcode.SourceCodeLanguage.BourneShellScript",
        "zsh-theme": "Xcode.SourceCodeLanguage.BourneShellScript",
        // PowerShell: the shell spec is the closest fit (# comments, "..."
        // strings, $variables, and shared keywords like function/if).
        "ps1": "Xcode.SourceCodeLanguage.BourneShellScript",
        "psm1": "Xcode.SourceCodeLanguage.BourneShellScript",
        "psd1": "Xcode.SourceCodeLanguage.BourneShellScript",
        // Dotfiles (.zshrc, .gitconfig, ...) are deliberately NOT listed:
        // extensionless files are classified by content structure instead,
        // so there is no name database to maintain.
        // C-family / Java relatives
        "rs": "Xcode.SourceCodeLanguage.C-Plus-Plus",
        "go": "Xcode.SourceCodeLanguage.C-Plus-Plus",
        "kt": "Xcode.SourceCodeLanguage.Java",
        "kts": "Xcode.SourceCodeLanguage.Java",
        "gradle": "Xcode.SourceCodeLanguage.Java",
        // Ruby relatives
        "gemspec": "Xcode.SourceCodeLanguage.Ruby",
        "podspec": "Xcode.SourceCodeLanguage.Ruby",
        "rake": "Xcode.SourceCodeLanguage.Ruby",
        // Config relatives
        "conf": "Xcode.SourceCodeLanguage.TOML_INI",
        "jsonl": "Xcode.SourceCodeLanguage.JSON",
        "xcconfig": "Xcode.SourceCodeLanguage.XcodeConfiguration",
        "properties": "Xcode.SourceCodeLanguage.TOML_INI",
        "env": "Xcode.SourceCodeLanguage.BourneShellScript",
        "cmake": "Xcode.SourceCodeLanguage.Makefile",
        "sql": "Xcode.SourceCodeLanguage.SQL",
        "diff": "Xcode.SourceCodeLanguage.UnifiedDiff",
        "patch": "Xcode.SourceCodeLanguage.UnifiedDiff",
        // Web relatives (html itself keeps its rendered system preview)
        "vue": "Xcode.SourceCodeLanguage.HTML",
        "svelte": "Xcode.SourceCodeLanguage.HTML",
    ]

    /// Exact filename (lowercased) → Xcode.SourceCodeLanguage identifier.
    /// Dotfiles don't belong here: detection strips their leading dot and
    /// routes the remainder through the extension tables above.
    static let filenameLanguageIDs: [String: String] = [
        "dockerfile": "Xcode.SourceCodeLanguage.BourneShellScript",
        "makefile": "Xcode.SourceCodeLanguage.Makefile",
        "gnumakefile": "Xcode.SourceCodeLanguage.Makefile",
        "cmakelists.txt": "Xcode.SourceCodeLanguage.Makefile",
        "rakefile": "Xcode.SourceCodeLanguage.Ruby",
        "gemfile": "Xcode.SourceCodeLanguage.Ruby",
        "podfile": "Xcode.SourceCodeLanguage.Ruby",
        "brewfile": "Xcode.SourceCodeLanguage.Ruby",
    ]

    /// ".env" → "env", "json" → "json": lets extensionless files (dotfiles,
    /// bare symlink targets) reuse the extension and alias tables when their
    /// whole name happens to be a known extension.
    static func pseudoExtension(forFilename filename: String) -> String? {
        let stripped = filename.drop(while: { $0 == "." })
        guard !stripped.isEmpty, !stripped.contains(".") else { return nil }
        return stripped.lowercased()
    }

    // MARK: Content classification

    /// Structure-based identification for extensionless files that nothing
    /// else matched (never consulted when an extension or UTI resolved).
    /// Distinguishes the handful of spec families that dotfiles and rc files
    /// actually use; anything ambiguous returns nil and the caller falls back
    /// to the generic spec.
    static func contentLanguageID(forTextPrefix prefix: String) -> String? {
        let trimmed = prefix.drop(while: \.isWhitespace)
        guard let first = trimmed.first else { return nil }

        // Markup: XML documents AND XML property lists both belong to the XML
        // spec (Xcode renders XML plists as XML too), so no plist special case
        // is needed on this branch.
        if first == "<", let second = trimmed.dropFirst().first,
           second == "?" || second == "!" || second.isLetter {
            return "Xcode.SourceCodeLanguage.XML"
        }

        // A YAML document-start marker — unless it opens markdown front
        // matter: a closing ---/... fence with body text after it means the
        // YAML is only the header, and coloring the whole file as YAML would
        // paint every markdown heading as a comment.
        if trimmed.hasPrefix("---\n") || trimmed.hasPrefix("---\r\n") || trimmed.hasPrefix("--- ") {
            let lines = Array(trimmed.split(separator: "\n", omittingEmptySubsequences: false).prefix(40))
            for index in lines.indices.dropFirst() {
                let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if line == "---" || line == "..." {
                    let hasBody = lines[(index + 1)...].contains {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    if hasBody { return "Xcode.SourceCodeLanguage.Markdown" }
                    break
                }
            }
            return "Xcode.SourceCodeLanguage.YAML"
        }

        // Brace documents: JSON vs old-style (ASCII) property list. They look
        // alike at the first byte; plists assign with `key = value;`, JSON
        // pairs with `"key": value,`. An INI [section] header also starts
        // with "[" — leave those to line voting.
        if first == "{" || first == "(" || (first == "[" && !firstLineIsSectionHeader(trimmed)) {
            let jsonPairs = occurrences(of: "\":", in: trimmed) + occurrences(of: "\" :", in: trimmed)
            let plistPairs = min(occurrences(of: " = ", in: trimmed), occurrences(of: ";", in: trimmed))
            if plistPairs > jsonPairs { return "Xcode.SourceCodeLanguage.TextPlist" }
            return "Xcode.SourceCodeLanguage.JSON"
        }

        // Line voting for shell / INI / YAML shapes. Signals are ranked:
        // structural shapes (sections, list items, pairs) are checked before
        // weak shell flavor, and assignments carrying quoted dollar-variables
        // count as "shell-flavored assignments" that only tip the scale when
        // some unambiguous shell line exists — a gitconfig alias like
        // `lg = log --pretty="$FMT"` must stay INI.
        var shellStrong = 0
        var shellAssignments = 0
        var iniSections = 0
        var assignments = 0
        var yamlPairs = 0
        var cDirectives = 0
        let shellStarters = [
            "export ", "alias ", "unalias ", "setopt ", "unsetopt ", "set -",
            "source ", ". /", "eval ", "shopt ", "autoload ", "bindkey ",
            "function ", "if [", "if [[", "case ", "esac", "fi", "then",
            "done", "for ", "while ", "echo ", "umask ", "ulimit ", "unset ",
        ]
        // Full split then prefix: split(maxSplits:) would return the entire
        // remainder as one mega-"line", so a long comment header (oh-my-zsh
        // templates) would swallow every line that carries actual votes.
        // Trimming must include newlines so CRLF input doesn't leave \r on
        // line ends and break suffix checks.
        for rawLine in trimmed.split(separator: "\n", omittingEmptySubsequences: true).prefix(120) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            // Include directives with their bracket/quote are unambiguously
            // C-family; a shell comment "#include stuff" never has one.
            if line.hasPrefix("#include <") || line.hasPrefix("#include \"")
                || line.hasPrefix("#import <") || line.hasPrefix("#import \"") {
                return "Xcode.SourceCodeLanguage.C"
            }
            // Weaker directives vote rather than decide: prose comments can
            // start with the same words.
            if line.hasPrefix("#define ") || line.hasPrefix("#ifndef ")
                || line.hasPrefix("#ifdef ") || line.hasPrefix("#pragma ") {
                cDirectives += 1
                continue
            }
            if line.hasPrefix("#") { continue }
            // Unambiguous shell: starter keywords, expansions, heredocs, and
            // POSIX function definitions (`name() {` — a BARE identifier
            // before the parens, so Swift/C `func f() {` doesn't match).
            if shellStarters.contains(where: line.hasPrefix) || line.contains("$(") || line.contains("${")
                || isShellFunctionDefinition(line)
                || (line.contains("<<") && !line.contains(";")) {
                shellStrong += 1
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]"), !line.contains("=") {
                iniSections += 1
                continue
            }
            if line.hasPrefix("- ") {
                yamlPairs += 1
                continue
            }
            if line.contains("=") {
                if line.contains("\"$") || line.contains("'$") {
                    shellAssignments += 1
                } else {
                    assignments += 1
                }
                continue
            }
            // "key: value" with a short key and no assignment flavor.
            if let colon = line.firstIndex(of: ":"),
               colon != line.startIndex,
               line[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) {
                yamlPairs += 1
            }
        }
        if shellStrong >= 2 || (shellStrong >= 1 && shellAssignments >= 1) {
            return "Xcode.SourceCodeLanguage.BourneShellScript"
        }
        if cDirectives >= 2, cDirectives > shellStrong { return "Xcode.SourceCodeLanguage.C" }
        if iniSections >= 1, assignments + shellAssignments >= 1 { return "Xcode.SourceCodeLanguage.TOML_INI" }
        if yamlPairs >= 3, assignments == 0, shellStrong == 0 { return "Xcode.SourceCodeLanguage.YAML" }
        return nil
    }

    /// The .d extension is DTrace in Xcode's tables, but compilers emit
    /// make-format dependency files with the same extension. Two shapes count
    /// as dependencies: a rule line whose target is a path-ish token before a
    /// colon (`build/main.o: src/main.c`), and rule-less fragments that are
    /// nothing but path lines with backslash continuations. DTrace probe
    /// descriptions (`syscall:::entry {`) are bare words with braces and
    /// statement semicolons.
    static func looksLikeMakeDependencies(forTextPrefix prefix: String) -> Bool {
        var pathLines = 0
        var considered = 0
        for raw in prefix.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Comment lines don't count against the inspection window, or a
            // generated header longer than the window hides the rule line.
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.contains("{") || line.contains(";") { return false }
            considered += 1
            if considered > 12 { break }
            if let colon = line.firstIndex(of: ":") {
                let target = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                if !target.isEmpty, !containsUnescapedSpace(target),
                   target.hasSuffix(".o") || target.contains("/") || target.contains(".") {
                    return true
                }
                return false
            }
            let core = line.hasSuffix("\\")
                ? line.dropLast().trimmingCharacters(in: .whitespaces)
                : line
            if !core.isEmpty, !containsUnescapedSpace(core), core.contains("/") || core.contains(".") {
                pathLines += 1
            } else {
                return false
            }
        }
        return considered >= 2 && pathLines == considered
    }

    /// Make escapes spaces in paths as "\ " (clang -MD emits them for any
    /// project under a spaced directory); only a bare space disqualifies.
    private static func containsUnescapedSpace(_ text: String) -> Bool {
        var previousWasBackslash = false
        for character in text {
            if character == " ", !previousWasBackslash { return true }
            previousWasBackslash = character == "\\"
        }
        return false
    }

    /// `path_prepend() {` is a POSIX function definition; `func f() {` is not:
    /// the text before "() {" must be one bare identifier.
    private static func isShellFunctionDefinition(_ line: String) -> Bool {
        guard line.hasSuffix("() {"), line.count > 4 else { return false }
        let name = line.dropLast(4)
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":" || $0 == "." }
    }

    /// `[user]` alone on the first line is an INI section, not a JSON array:
    /// no commas, no quotes, closing bracket at end of line.
    private static func firstLineIsSectionHeader(_ text: Substring) -> Bool {
        let firstLine = text.prefix(while: { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
        return firstLine.count > 2 && firstLine.hasPrefix("[") && firstLine.hasSuffix("]")
            && !firstLine.contains(",") && !firstLine.contains("\"") && !firstLine.contains(":")
    }

    private static func occurrences(of needle: String, in text: Substring) -> Int {
        var count = 0
        var search = text.startIndex
        while let found = text.range(of: needle, range: search..<text.endIndex) {
            count += 1
            search = found.upperBound
        }
        return count
    }

    /// Property lists have no owning language in the metadata (TextPlist
    /// declares no file types); XML plists belong to the XML spec, old-style
    /// ASCII plists to the plist spec.
    static let plistUTIs: Set<String> = [
        "com.apple.property-list",
        "com.apple.xml-property-list",
        "com.apple.ascii-property-list",
    ]

    static func plistLanguageID(firstLine: String?) -> String {
        if let firstLine, firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("<") {
            return "Xcode.SourceCodeLanguage.XML"
        }
        return "Xcode.SourceCodeLanguage.TextPlist"
    }

    /// Interpreter basename (version digits stripped) → language identifier.
    private static let shebangLanguageIDs: [String: String] = [
        "sh": "Xcode.SourceCodeLanguage.BourneShellScript",
        "bash": "Xcode.SourceCodeLanguage.BourneShellScript",
        "zsh": "Xcode.SourceCodeLanguage.BourneShellScript",
        "dash": "Xcode.SourceCodeLanguage.BourneShellScript",
        "ksh": "Xcode.SourceCodeLanguage.BourneShellScript",
        "fish": "Xcode.SourceCodeLanguage.BourneShellScript",
        "python": "Xcode.SourceCodeLanguage.Python",
        "ruby": "Xcode.SourceCodeLanguage.Ruby",
        "perl": "Xcode.SourceCodeLanguage.Perl",
        "node": "Xcode.SourceCodeLanguage.JavaScript",
        "swift": "Xcode.SourceCodeLanguage.Swift",
        "php": "Xcode.SourceCodeLanguage.PHP",
        "osascript": "Xcode.SourceCodeLanguage.AppleScript",
    ]

    /// Parses "#!/usr/bin/env python3" style shebang lines.
    static func shebangLanguageID(firstLine: String) -> String? {
        guard firstLine.hasPrefix("#!") else { return nil }
        var components = firstLine.dropFirst(2)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard var interpreter = components.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else {
            return nil
        }
        if interpreter == "env", components.count > 1 {
            // Skip env flags like -S; take the first non-flag word.
            components.removeFirst()
            guard let real = components.first(where: { !$0.hasPrefix("-") }) else { return nil }
            interpreter = URL(fileURLWithPath: real).lastPathComponent
        }
        let stripped = interpreter.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
        return shebangLanguageIDs[stripped.lowercased()]
    }
}
