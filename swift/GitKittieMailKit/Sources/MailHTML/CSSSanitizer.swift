import Foundation

/// Makes mail CSS inert for the network: no `@import`, no `@font-face`, no `url()` except to
/// an inline part of the same message, no `image-set()`, no legacy script hooks. CSS escapes
/// are decoded first, so `u\72 l(` cannot hide a `url(`. Layout and colour stay.
///
/// This is one of four layers (ThreatModel §1): the content rule list, the CSP and the web
/// view's navigation lock each block a remote load on their own; this layer means the remote
/// reference never reaches the web view in the first place.
public enum CSSSanitizer {
    public struct Result: Equatable, Sendable {
        public var css: String
        /// `url()` and similar references removed because they pointed off the message.
        public var blockedReferences: Int
        /// `cid:` references kept (rewritten through `resolveContentID`).
        public var contentIDs: [String]
    }

    /// - Parameter resolveContentID: maps a `cid:` reference to the URL the reader serves it at.
    public static func sanitize(_ input: String, resolveContentID: (String) -> String?) -> Result {
        var css = decodeEscapes(stripComments(input))
        var blocked = 0
        var contentIDs: [String] = []

        // At-rules that load or define remote resources, or that we never want: drop them whole.
        for rule in ["@import", "@font-face", "@namespace", "@charset", "@document", "@-moz-document"] {
            while let range = css.range(of: rule, options: .caseInsensitive) {
                let end = endOfAtRule(css, from: range.upperBound)
                if rule == "@import" || rule == "@font-face" { blocked += 1 }
                css.replaceSubrange(range.lowerBound..<end, with: "")
            }
        }

        // Declarations that can run code or load by other means.
        for pattern in [#"(?i)expression\s*\("#, #"(?i)behaviou?r\s*:"#, #"(?i)-moz-binding"#, #"(?i)javascript\s*:"#, #"(?i)vbscript\s*:"#] {
            css = css.replacingOccurrences(of: pattern, with: "x-blocked(", options: .regularExpression)
        }
        // image-set()/-webkit-image-set() take bare strings as URLs.
        while let range = css.range(of: #"(?i)(-webkit-)?image-set\s*\("#, options: .regularExpression) {
            let end = endOfParenthesis(css, openingAt: css.index(before: range.upperBound))
            css.replaceSubrange(range.lowerBound..<end, with: "none")
            blocked += 1
        }

        // url(…): keep only cid: references, rewritten to the reader's own scheme.
        var output = ""
        var rest = Substring(css)
        while let range = rest.range(of: #"(?i)url\s*\("#, options: .regularExpression) {
            output += rest[rest.startIndex..<range.lowerBound]
            let open = rest.index(before: range.upperBound)
            let close = endOfParenthesis(in: rest, openingAt: open)
            let innerEnd = close > range.upperBound && rest[rest.index(before: close)] == ")" ? rest.index(before: close) : close
            let inner = rest[range.upperBound..<innerEnd]
            let target = inner.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespaces)
            if target.lowercased().hasPrefix("cid:"), let resolved = resolveContentID(String(target.dropFirst(4))) {
                contentIDs.append(String(target.dropFirst(4)))
                output += "url(\"\(resolved)\")"
            } else {
                blocked += 1
                output += "none"
            }
            rest = rest[close...]
        }
        output += rest

        // The result is placed inside <style>: it must never be able to close that element.
        output = output.replacingOccurrences(of: "<", with: "\\3C ")
        return Result(css: output, blockedReferences: blocked, contentIDs: contentIDs)
    }

    /// Sanitizes a `style="…"` attribute: same rules, and no braces (a declaration list only).
    public static func sanitizeDeclarations(_ input: String, resolveContentID: (String) -> String?) -> Result {
        var result = sanitize(input, resolveContentID: resolveContentID)
        result.css = result.css.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return result
    }

    static func stripComments(_ css: String) -> String {
        var out = ""
        var rest = Substring(css)
        while let open = rest.range(of: "/*") {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "*/") else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// CSS escapes (CSS Syntax 4.3.7): `\` + 1–6 hex digits (+ one optional space), or `\` + any
    /// other character, which stands for itself. A backslash before a newline is dropped.
    static func decodeEscapes(_ css: String) -> String {
        guard css.contains("\\") else { return css }
        let scalars = Array(css.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "\\", i + 1 < scalars.count else { out.append(scalars[i]); i += 1; continue }
            var j = i + 1
            var hex = ""
            while j < scalars.count, hex.count < 6, scalars[j].properties.isASCIIHexDigit { hex.unicodeScalars.append(scalars[j]); j += 1 }
            if !hex.isEmpty {
                if j < scalars.count, scalars[j] == " " || scalars[j] == "\t" || scalars[j] == "\n" { j += 1 }
                let value = UInt32(hex, radix: 16) ?? 0xFFFD
                out.append(value == 0 || value > 0x10FFFF || (0xD800...0xDFFF).contains(value) ? "\u{FFFD}" : Unicode.Scalar(value)!)
                i = j
            } else if scalars[j] == "\n" {
                i = j + 1
            } else {
                out.append(scalars[j])
                i = j + 1
            }
        }
        return String(out)
    }

    /// The end of an at-rule: after its `;`, or after its balanced `{…}` block, or the end.
    private static func endOfAtRule(_ css: String, from start: String.Index) -> String.Index {
        var depth = 0
        var index = start
        while index < css.endIndex {
            switch css[index] {
            case ";" where depth == 0: return css.index(after: index)
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth <= 0 { return css.index(after: index) }
            default: break
            }
            index = css.index(after: index)
        }
        return css.endIndex
    }

    /// The index after the `)` that closes the `(` at `open`, skipping quoted strings.
    private static func endOfParenthesis(_ css: String, openingAt open: String.Index) -> String.Index {
        endOfParenthesis(in: Substring(css), openingAt: open)
    }

    private static func endOfParenthesis(in text: Substring, openingAt open: String.Index) -> String.Index {
        var depth = 0
        var quote: Character?
        var index = open
        while index < text.endIndex {
            let c = text[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }
}
