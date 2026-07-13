import Foundation

/// Whitespace-only pretty-printing for minified JSON. Deliberately NOT a
/// parse-and-reserialize: a byte-level reindent preserves key order, number
/// precision, and every byte inside strings, runs in one O(n) pass, and
/// degrades gracefully on invalid or truncated input (extra closers clamp,
/// unterminated strings pass through).
nonisolated enum JSONReformatter {

    /// Reindents one JSON value (or line) with two-space indentation.
    /// Existing inter-token whitespace is collapsed, so the result is stable
    /// under repeated application.
    static func reindent(_ input: Substring) -> String {
        let bytes = Array(input.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + bytes.count / 4)
        var depth = 0
        var inString = false
        var escaped = false

        func newlineAndIndent(_ level: Int) {
            out.append(0x0A)
            for _ in 0..<max(level, 0) {
                out.append(0x20)
                out.append(0x20)
            }
        }

        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if inString {
                out.append(byte)
                if escaped {
                    escaped = false
                } else if byte == 0x5C {  // backslash
                    escaped = true
                } else if byte == 0x22 {  // quote
                    inString = false
                }
                i += 1
                continue
            }
            switch byte {
            case 0x22:  // quote: string begins
                out.append(byte)
                inString = true
                i += 1
            case 0x7B, 0x5B:  // { [
                out.append(byte)
                // Keep empty containers on one line: peek past whitespace for
                // the matching closer (} is {+2, ] is [+2 in ASCII).
                var j = i + 1
                while j < bytes.count,
                      bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D {
                    j += 1
                }
                if j < bytes.count, bytes[j] == byte + 2 {
                    out.append(bytes[j])
                    i = j + 1
                } else {
                    depth += 1
                    newlineAndIndent(depth)
                    i += 1
                }
            case 0x7D, 0x5D:  // } ]
                depth -= 1
                newlineAndIndent(depth)
                out.append(byte)
                i += 1
            case 0x2C:  // ,
                out.append(byte)
                newlineAndIndent(depth)
                i += 1
            case 0x3A:  // :
                out.append(byte)
                out.append(0x20)
                i += 1
            case 0x20, 0x09, 0x0A, 0x0D:  // collapse existing whitespace
                i += 1
            default:
                out.append(byte)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
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
    static func job(for text: String) -> (initial: String, remaining: [Substring])? {
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
            return (reindent(lines[0]), [])
        }
        var initial = ""
        var consumed = 0
        var index = 0
        while index < lines.count, consumed < 128 * 1024 {
            initial += reindent(lines[index])
            initial += "\n\n"
            consumed += lines[index].utf8.count
            index += 1
        }
        return (initial, Array(lines[index...]))
    }
}
