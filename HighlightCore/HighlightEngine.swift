import Foundation

/// One colored range in the source text. Spans are ordered parents-first
/// (pre-order); appliers must honor that order so children override parents.
nonisolated struct TokenSpan: Sendable {
    var range: NSRange
    /// Full node type name, e.g. "xcode.syntax.keyword", or nil for an
    /// explicit reset to the default style (plain code inside a colored
    /// ancestor, like string interpolation segments).
    var nodeTypeName: String?
}

/// Owns all non-Sendable SourceModel objects and does every piece of
/// highlighting work off the main thread.
actor HighlightEngine {

    static let shared = HighlightEngine()

    /// Files larger than this are shown without highlighting.
    static let maxHighlightableUTF16Length = 8 * 1024 * 1024

    enum EngineError: Error {
        case frameworkUnavailable
        case noLanguage
        case parseFailed
        case textTooLarge
    }

    private let frameworkURL: URL?
    private var client: SourceModelClient?
    private var clientError: (any Error)?
    private var themes: [Bool: Theme] = [:]

    /// - Parameter frameworkURL: overrides SourceModel.framework discovery
    ///   (used by tests to load the repo copy); nil resolves the installed Xcode.
    init(frameworkURL: URL? = nil) {
        self.frameworkURL = frameworkURL
    }

    private func loadedClient() throws -> SourceModelClient {
        if let client { return client }
        if let clientError { throw clientError }
        do {
            guard let url = frameworkURL ?? XcodeLocator.sourceModelFrameworkURL() else {
                throw EngineError.frameworkUnavailable
            }
            let loaded = try SourceModelClient(frameworkURL: url)
            client = loaded
            return loaded
        } catch {
            clientError = error
            throw error
        }
    }

    /// Whether SourceModel can be loaded at all (used to decline previews early).
    func isAvailable() -> Bool {
        (try? loadedClient()) != nil
    }

    /// Human-readable reason the engine is unavailable, if it is.
    func availabilityFailureDescription() -> String? {
        guard !isAvailable() else { return nil }
        return clientError.map { String(describing: $0) }
    }

    // MARK: Themes

    func theme(dark: Bool) throws -> Theme {
        if let cached = themes[dark] { return cached }
        guard let url = XcodeLocator.defaultThemeURL(dark: dark) else {
            throw EngineError.frameworkUnavailable
        }
        let theme = try Theme.load(from: url)
        themes[dark] = theme
        return theme
    }

    // MARK: Highlighting

    /// Parses `text` and returns render-ready spans: only node types the theme
    /// actually styles are emitted, plus explicit resets for unstyled code
    /// nested inside styled ranges (e.g. string interpolation segments).
    /// Light and dark Default themes style the same node types, so spans
    /// computed against one remain valid for the other.
    func tokenize(text: String, hint: LanguageHint, theme: Theme) throws -> [TokenSpan] {
        let client = try loadedClient()
        guard let language = detectLanguage(hint, textPrefix: String(text.prefix(4096)), client: client) else {
            throw EngineError.noLanguage
        }
        let nsText = text as NSString
        guard nsText.length <= Self.maxHighlightableUTF16Length else {
            throw EngineError.textTooLarge
        }
        guard let (root, retained) = client.parse(text: nsText, language: language) else {
            throw EngineError.parseFailed
        }
        defer { withExtendedLifetime(retained) {} }

        var spans: [TokenSpan] = []
        // Iterative pre-order walk; parser trees for minified files can be too
        // deep for recursion on a cooperative-pool stack.
        var stack: [(item: any XCQLSourceModelItem, parentStyled: Bool)] = [(root, false)]
        while let (item, parentStyled) = stack.popLast() {
            let name = client.nodeTypeName(forId: item.nodeType())
            let styled = name.map { theme.style(forNodeTypeName: $0) != nil } ?? false
            if styled {
                spans.append(TokenSpan(range: item.range(), nodeTypeName: name))
            } else if parentStyled {
                spans.append(TokenSpan(range: item.range(), nodeTypeName: nil))
            }
            if let children = item.children(), !children.isEmpty {
                // A reset was emitted whenever this item is unstyled under a
                // styled ancestor, so children only see this item's own state.
                // Reverse so popLast() visits children in document order.
                for child in children.reversed() {
                    stack.append((client.item(child as AnyObject), styled))
                }
            }
        }
        return spans
    }

    private func detectLanguage(_ hint: LanguageHint, textPrefix: String, client: SourceModelClient) -> AnyObject? {
        for uti in hint.contentTypeIdentifiers {
            if let language = client.language(forUTI: uti) { return language }
        }
        if hint.contentTypeIdentifiers.contains(where: LanguageDetector.plistUTIs.contains) {
            let id = LanguageDetector.plistLanguageID(firstLine: hint.firstLine)
            if let language = client.language(forIdentifier: id) { return language }
        }
        if let ext = hint.fileExtension?.lowercased(), !ext.isEmpty {
            if let language = client.language(forExtension: ext) { return language }
            if let id = LanguageDetector.aliasLanguageIDs[ext],
               let language = client.language(forIdentifier: id) { return language }
        }
        if let filename = hint.filename?.lowercased() {
            if let id = LanguageDetector.filenameLanguageIDs[filename],
               let language = client.language(forIdentifier: id) {
                return language
            }
            // Extensionless files (.zprofile, a symlink target named "zshrc")
            // carry their whole identity in the name; reuse the extension
            // machinery for it. The framework's full extension table only
            // applies to dotfiles — a prose file that happens to be named
            // "swift" must not tokenize as Swift — while the curated alias
            // table applies to bare names too.
            if hint.fileExtension == nil || hint.fileExtension?.isEmpty == true,
               let pseudo = LanguageDetector.pseudoExtension(forFilename: filename) {
                if filename.hasPrefix("."),
                   let language = client.language(forExtension: pseudo) {
                    return language
                }
                if let id = LanguageDetector.aliasLanguageIDs[pseudo],
                   let language = client.language(forIdentifier: id) {
                    return language
                }
            }
        }
        if let firstLine = hint.firstLine,
           let id = LanguageDetector.shebangLanguageID(firstLine: firstLine),
           let language = client.language(forIdentifier: id) {
            return language
        }
        // Content classification and the generic floor apply when the type
        // system has no real opinion about the file: extensionless names
        // (dotfiles, rc files) and unknown extensions that only earned a
        // dynamic or catch-all UTI (.env.local, .xyz). Files with a
        // system-declared type (like .txt → public.plain-text) never get
        // second-guessed by content.
        let isExtensionless = hint.fileExtension?.isEmpty != false
        let typeSystemHasNoOpinion = hint.contentTypeIdentifiers.isEmpty
            || hint.contentTypeIdentifiers.allSatisfy { $0.hasPrefix("dyn.") || $0 == "public.data" }
        if isExtensionless || typeSystemHasNoOpinion {
            if let id = LanguageDetector.contentLanguageID(forTextPrefix: textPrefix),
               let language = client.language(forIdentifier: id) {
                return language
            }
            if let language = client.language(forIdentifier: "Xcode.SourceCodeLanguage.Generic") {
                return language
            }
        }
        if hint.conformsToSourceCode,
           let language = client.language(forIdentifier: "Xcode.SourceCodeLanguage.Generic") {
            return language
        }
        return nil
    }
}
