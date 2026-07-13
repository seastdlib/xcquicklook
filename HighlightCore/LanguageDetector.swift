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

        // A YAML document-start marker is unambiguous.
        if trimmed.hasPrefix("---\n") || trimmed.hasPrefix("--- ") {
            return "Xcode.SourceCodeLanguage.YAML"
        }

        // Brace documents: JSON vs old-style (ASCII) property list. They look
        // alike at the first byte; plists assign with `key = value;`, JSON
        // pairs with `"key": value,`.
        if first == "{" || first == "[" || first == "(" {
            let jsonPairs = occurrences(of: "\":", in: trimmed) + occurrences(of: "\" :", in: trimmed)
            let plistPairs = min(occurrences(of: " = ", in: trimmed), occurrences(of: ";", in: trimmed))
            if plistPairs > jsonPairs { return "Xcode.SourceCodeLanguage.TextPlist" }
            return "Xcode.SourceCodeLanguage.JSON"
        }

        // Line voting for shell / INI / YAML shapes.
        var shell = 0
        var iniSections = 0
        var assignments = 0
        var yamlPairs = 0
        let shellStarters = [
            "export ", "alias ", "unalias ", "setopt ", "unsetopt ", "set -",
            "source ", ". /", "eval ", "shopt ", "autoload ", "bindkey ",
            "function ", "if [", "if [[", "case ", "esac", "fi", "then",
            "done", "for ", "while ", "echo ", "umask ", "ulimit ", "unset ",
        ]
        for rawLine in trimmed.split(separator: "\n", maxSplits: 80, omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Preprocessor directives are C-family, not comments; "#include"
            // etc. have no space after the hash, unlike prose comments.
            if line.hasPrefix("#include") || line.hasPrefix("#import")
                || line.hasPrefix("#pragma") || line.hasPrefix("#ifndef") {
                return "Xcode.SourceCodeLanguage.C"
            }
            if line.hasPrefix("#") { continue }
            if shellStarters.contains(where: line.hasPrefix) || line.contains("$(") || line.contains("${") {
                shell += 1
                continue
            }
            if line.hasPrefix("["), line.hasSuffix("]"), !line.contains("=") {
                iniSections += 1
                continue
            }
            if line.contains("="), !line.hasPrefix("- ") {
                assignments += 1
                continue
            }
            // "key: value" with a short key and no assignment flavor.
            if let colon = line.firstIndex(of: ":"),
               colon != line.startIndex,
               line[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) {
                yamlPairs += 1
            }
        }
        if shell >= 2, shell >= assignments { return "Xcode.SourceCodeLanguage.BourneShellScript" }
        if iniSections >= 1, assignments >= 1 { return "Xcode.SourceCodeLanguage.TOML_INI" }
        if yamlPairs >= 3, assignments == 0, shell == 0 { return "Xcode.SourceCodeLanguage.YAML" }
        return nil
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
