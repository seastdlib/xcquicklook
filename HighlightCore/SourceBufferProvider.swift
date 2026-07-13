import Foundation

/// The buffer object handed to -[SMSourceModel initWithSourceBufferProvider:].
/// Immutable; safe to message from whatever thread SourceModel parses on.
nonisolated final class SourceBufferProvider: NSObject, XCQLBufferProviding {
    private let text: NSString
    private let sourceLanguage: AnyObject

    init(text: NSString, language: AnyObject) {
        self.text = text
        self.sourceLanguage = language
    }

    func stringAsId() -> Any {
        text
    }

    func length() -> UInt {
        UInt(text.length)
    }

    func language() -> Any? {
        sourceLanguage
    }

    func lineRange(forCharacterRange range: NSRange) -> NSRange {
        text.lineRange(for: range)
    }

    func scheduleLazyInvalidation(for range: NSRange) {
        // Only meaningful for incremental editing; previews parse once.
    }
}
