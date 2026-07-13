import Foundation

/// Whitespace-oriented pretty-printing for minified JSON. Deliberately NOT a
/// parse-and-reserialize: a byte-level pass preserves key order, number
/// precision, and string content, runs in O(n), and degrades gracefully on
/// invalid or truncated input.
///
/// Two display liberties are taken for readability: `\n` escapes inside
/// strings become real newlines with the continuation indented to the
/// string's starting column, and inter-token whitespace is normalized.
/// Because the result is no longer valid JSON, this formatter also emits the
/// authoritative token spans (strings, numbers, keywords) — the JSON grammar
/// would otherwise terminate a string at the injected newline.
nonisolated enum JSONReformatter {

    /// Reindents one JSON value and reports token spans. `utf16Offset` is
    /// the absolute UTF-16 position at which this text will be placed, so
    /// span ranges land directly in the final storage's coordinates.
    static func reindentWithSpans(
        _ input: Substring,
        utf16Offset: Int,
        expandNewlines: Bool = false
    ) -> (text: String, spans: [TokenSpan]) {
        let bytes = Array(input.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + bytes.count / 4)
        var spans: [TokenSpan] = []
        var depth = 0
        var utf16Pos = utf16Offset
        var column = 0  // UTF-16 units since the current line start

        func append(_ byte: UInt8) {
            out.append(byte)
            // UTF-16 length: lead bytes count 1 (2 for astral); continuations 0.
            if byte & 0xC0 != 0x80 {
                let units = byte >= 0xF0 ? 2 : 1
                utf16Pos += units
                column = byte == 0x0A ? 0 : column + units
            }
        }

        func newlineAndIndent(_ level: Int) {
            append(0x0A)
            for _ in 0..<max(level, 0) {
                append(0x20)
                append(0x20)
            }
        }

        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            switch byte {
            case 0x22:  // quote: consume the whole string as one token
                let spanStart = utf16Pos
                let continuationIndent = column + 1
                append(byte)
                i += 1
                var closed = false
                while i < bytes.count {
                    let b = bytes[i]
                    if b == 0x5C, i + 1 < bytes.count {  // escape pair
                        if expandNewlines, bytes[i + 1] == 0x6E {  // \n: real break, aligned
                            append(0x0A)
                            for _ in 0..<continuationIndent { append(0x20) }
                        } else {
                            append(b)
                            append(bytes[i + 1])
                        }
                        i += 2
                        continue
                    }
                    append(b)
                    i += 1
                    if b == 0x22 {
                        closed = true
                        break
                    }
                }
                _ = closed  // unterminated strings span to end of input
                spans.append(TokenSpan(
                    range: NSRange(location: spanStart, length: utf16Pos - spanStart),
                    nodeTypeName: "xcode.syntax.string"
                ))
            case 0x7B, 0x5B:  // { [
                append(byte)
                // Keep empty containers on one line (} is {+2, ] is [+2).
                var j = i + 1
                while j < bytes.count,
                      bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D {
                    j += 1
                }
                if j < bytes.count, bytes[j] == byte + 2 {
                    append(bytes[j])
                    i = j + 1
                } else {
                    depth += 1
                    newlineAndIndent(depth)
                    i += 1
                }
            case 0x7D, 0x5D:  // } ]
                depth -= 1
                newlineAndIndent(depth)
                append(byte)
                i += 1
            case 0x2C:  // ,
                append(byte)
                newlineAndIndent(depth)
                i += 1
            case 0x3A:  // :
                append(byte)
                append(0x20)
                i += 1
            case 0x20, 0x09, 0x0A, 0x0D:  // collapse existing whitespace
                i += 1
            case 0x2D, 0x30...0x39:  // number token
                let spanStart = utf16Pos
                while i < bytes.count, isNumberByte(bytes[i]) {
                    append(bytes[i])
                    i += 1
                }
                spans.append(TokenSpan(
                    range: NSRange(location: spanStart, length: utf16Pos - spanStart),
                    nodeTypeName: "xcode.syntax.number"
                ))
            case 0x74, 0x66, 0x6E:  // t f n → true/false/null keywords
                if let keyword = matchKeyword(bytes, at: i) {
                    let spanStart = utf16Pos
                    for b in keyword.utf8 { append(b) }
                    i += keyword.utf8.count
                    spans.append(TokenSpan(
                        range: NSRange(location: spanStart, length: utf16Pos - spanStart),
                        nodeTypeName: "xcode.syntax.keyword"
                    ))
                } else {
                    append(byte)
                    i += 1
                }
            default:
                append(byte)
                i += 1
            }
        }
        return (String(decoding: out, as: UTF8.self), spans)
    }

    /// Text-only variant, for callers and tests that don't need spans.
    static func reindent(_ input: Substring, expandNewlines: Bool = false) -> String {
        reindentWithSpans(input, utf16Offset: 0, expandNewlines: expandNewlines).text
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x2B || byte == 0x2E
            || byte == 0x65 || byte == 0x45  // e E
    }

    private static func matchKeyword(_ bytes: [UInt8], at index: Int) -> String? {
        for keyword in ["true", "false", "null"] {
            let expected = Array(keyword.utf8)
            if index + expected.count <= bytes.count,
               Array(bytes[index..<(index + expected.count)]) == expected {
                // Must not be a prefix of a longer word.
                let next = index + expected.count
                if next >= bytes.count || !isIdentifierByte(bytes[next]) {
                    return keyword
                }
            }
        }
        return nil
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (0x61...0x7A).contains(byte) || (0x41...0x5A).contains(byte)
            || (0x30...0x39).contains(byte) || byte == 0x5F
    }

    /// A line worth reformatting: long enough to be unreadable and actually
    /// structured (short or scalar lines pass through untouched).
    static func lineNeedsReformatting(_ line: Substring) -> Bool {
        line.utf8.count > 200 && (line.first == "{" || line.first == "[")
    }

    /// Splits JSON/JSONL text into a synchronously-formatted head (enough to
    /// fill any viewport instantly) and the raw remaining lines for
    /// asynchronous continuation. Returns nil when the text doesn't benefit
    /// (already pretty, not JSON-shaped, or a huge single document).
    static func job(for text: String, expandNewlines: Bool = false) -> (initial: String, initialSpans: [TokenSpan], remaining: [Substring])? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first,
              first.hasPrefix("{") || first.hasPrefix("["),
              lines.contains(where: lineNeedsReformatting) else {
            return nil
        }
        // A single minified document can't be streamed line-wise; format it
        // whole when that's still instant-adjacent, otherwise leave it raw.
        if lines.count == 1 {
            guard text.utf8.count <= 4 * 1024 * 1024 else { return nil }
            let (formatted, spans) = reindentWithSpans(lines[0], utf16Offset: 0, expandNewlines: expandNewlines)
            return (formatted, spans, [])
        }
        var initial = ""
        var spans: [TokenSpan] = []
        var consumed = 0
        var index = 0
        while index < lines.count, consumed < 128 * 1024 {
            let (formatted, lineSpans) = reindentWithSpans(
                lines[index], utf16Offset: initial.utf16.count, expandNewlines: expandNewlines
            )
            initial += formatted
            initial += "\n\n"
            spans.append(contentsOf: lineSpans)
            consumed += lines[index].utf8.count
            index += 1
        }
        return (initial, spans, Array(lines[index...]))
    }
}
