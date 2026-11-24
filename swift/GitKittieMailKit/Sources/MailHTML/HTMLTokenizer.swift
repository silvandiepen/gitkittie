import Foundation

/// One piece of an HTML document, as the sanitizer and the text extractor see it.
public enum HTMLToken: Equatable, Sendable {
    case text(String)
    /// Name lowercased; attribute names lowercased, values with character references decoded.
    case startTag(name: String, attributes: [HTMLAttribute], selfClosing: Bool)
    case endTag(name: String)
    /// The text of a raw-text element (`script`, `style`, `textarea`, `title`, …), undecoded.
    case rawText(element: String, text: String)
    case comment
    case doctype
}

public struct HTMLAttribute: Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A forgiving HTML tokenizer, modelled on the HTML5 tokenizer states that matter for mail:
/// tags, attributes in every quoting style, comments, bogus comments, doctypes and raw-text
/// elements. It never fails: anything it cannot read as markup is text. It does not build a
/// tree; the sanitizer works on the token stream and re-serializes only what it allows, so a
/// construct this tokenizer misreads ends up as escaped text, never as live markup.
public enum HTMLTokenizer {
    /// Elements whose content is not markup: everything up to the matching end tag is one token.
    static let rawTextElements: Set<String> = [
        "script", "style", "xmp", "iframe", "noembed", "noframes", "textarea", "title", "plaintext",
    ]

    /// Hard limit on input size: mail HTML beyond this is cut (the original stays in the `.eml`).
    public static let maximumInputLength = 8 * 1024 * 1024

    public static func tokenize(_ html: String) -> [HTMLToken] {
        var scalars = Array(html.unicodeScalars)
        if scalars.count > maximumInputLength { scalars = Array(scalars.prefix(maximumInputLength)) }
        var tokens: [HTMLToken] = []
        var text = String.UnicodeScalarView()
        var index = 0
        let count = scalars.count

        func flushText() {
            if !text.isEmpty {
                tokens.append(.text(CharacterReferences.decode(String(text), inAttribute: false)))
                text = String.UnicodeScalarView()
            }
        }

        while index < count {
            let scalar = scalars[index]
            guard scalar == "<", index + 1 < count else {
                text.append(scalar)
                index += 1
                continue
            }
            let next = scalars[index + 1]
            if next == "!" {
                // Comment, doctype, CDATA or bogus comment: all end the same way for us.
                if matches(scalars, at: index + 2, "--") {
                    flushText()
                    index = endOfComment(scalars, from: index + 4)
                    tokens.append(.comment)
                } else if matchesInsensitive(scalars, at: index + 2, "doctype") {
                    flushText()
                    index = after(">", in: scalars, from: index + 2)
                    tokens.append(.doctype)
                } else {
                    flushText()
                    index = after(">", in: scalars, from: index + 2)
                    tokens.append(.comment)
                }
                continue
            }
            if next == "?" {
                flushText()
                index = after(">", in: scalars, from: index + 2)
                tokens.append(.comment)
                continue
            }
            if next == "/" {
                guard index + 2 < count, isASCIILetter(scalars[index + 2]) else {
                    if index + 2 < count, scalars[index + 2] == ">" { index += 3; continue } // "</>" is dropped
                    // "</" + non-letter: a bogus comment in HTML5.
                    flushText()
                    index = after(">", in: scalars, from: index + 2)
                    tokens.append(.comment)
                    continue
                }
                flushText()
                var cursor = index + 2
                let name = readTagName(scalars, &cursor)
                cursor = after(">", in: scalars, from: cursor)
                tokens.append(.endTag(name: name))
                index = cursor
                continue
            }
            guard isASCIILetter(next) else {
                text.append(scalar)
                index += 1
                continue
            }
            flushText()
            var cursor = index + 1
            let name = readTagName(scalars, &cursor)
            var attributes: [HTMLAttribute] = []
            var selfClosing = false
            var seen = Set<String>()
            attributeLoop: while cursor < count {
                let c = scalars[cursor]
                if isSpace(c) { cursor += 1; continue }
                if c == ">" { cursor += 1; break attributeLoop }
                if c == "/" {
                    if cursor + 1 < count, scalars[cursor + 1] == ">" { selfClosing = true; cursor += 2; break attributeLoop }
                    cursor += 1
                    continue
                }
                // Attribute name: up to whitespace, "/", ">" or "=" (a leading "=" belongs to the name).
                var attributeName = String.UnicodeScalarView()
                attributeName.append(c)
                cursor += 1
                while cursor < count {
                    let d = scalars[cursor]
                    if isSpace(d) || d == "/" || d == ">" || d == "=" { break }
                    attributeName.append(d)
                    cursor += 1
                }
                while cursor < count, isSpace(scalars[cursor]) { cursor += 1 }
                var value = ""
                if cursor < count, scalars[cursor] == "=" {
                    cursor += 1
                    while cursor < count, isSpace(scalars[cursor]) { cursor += 1 }
                    if cursor < count, scalars[cursor] == "\"" || scalars[cursor] == "'" {
                        let quote = scalars[cursor]
                        cursor += 1
                        var raw = String.UnicodeScalarView()
                        while cursor < count, scalars[cursor] != quote { raw.append(scalars[cursor]); cursor += 1 }
                        cursor += 1 // closing quote (or past the end)
                        value = String(raw)
                    } else {
                        var raw = String.UnicodeScalarView()
                        while cursor < count, !isSpace(scalars[cursor]), scalars[cursor] != ">" { raw.append(scalars[cursor]); cursor += 1 }
                        value = String(raw)
                    }
                }
                let lowered = String(attributeName).lowercased()
                // HTML5: a repeated attribute is ignored; the first one wins.
                if seen.insert(lowered).inserted {
                    attributes.append(HTMLAttribute(name: lowered, value: CharacterReferences.decode(value, inAttribute: true)))
                }
            }
            tokens.append(.startTag(name: name, attributes: attributes, selfClosing: selfClosing))
            index = cursor
            if rawTextElements.contains(name), !selfClosing {
                if name == "plaintext" {
                    tokens.append(.rawText(element: name, text: String(String.UnicodeScalarView(scalars[min(index, count)...]))))
                    index = count
                    continue
                }
                let end = endOfRawText(scalars, element: name, from: index)
                tokens.append(.rawText(element: name, text: String(String.UnicodeScalarView(scalars[index..<end.contentEnd]))))
                if end.contentEnd < count { tokens.append(.endTag(name: name)) }
                index = end.next
            }
        }
        flushText()
        return tokens
    }

    // MARK: Scanning helpers

    private static func isASCIILetter(_ s: Unicode.Scalar) -> Bool { (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") }
    private static func isSpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" || s == "\n" || s == "\r" || s == "\u{0C}" }

    private static func readTagName(_ scalars: [Unicode.Scalar], _ cursor: inout Int) -> String {
        var name = String.UnicodeScalarView()
        while cursor < scalars.count {
            let c = scalars[cursor]
            if isSpace(c) || c == "/" || c == ">" { break }
            name.append(c)
            cursor += 1
        }
        return String(name).lowercased()
    }

    private static func matches(_ scalars: [Unicode.Scalar], at index: Int, _ literal: String) -> Bool {
        var i = index
        for s in literal.unicodeScalars {
            guard i < scalars.count, scalars[i] == s else { return false }
            i += 1
        }
        return true
    }

    private static func matchesInsensitive(_ scalars: [Unicode.Scalar], at index: Int, _ literal: String) -> Bool {
        var i = index
        for s in literal.unicodeScalars {
            guard i < scalars.count, String(scalars[i]).lowercased() == String(s) else { return false }
            i += 1
        }
        return true
    }

    /// Index after the next `target`, or the end.
    private static func after(_ target: Unicode.Scalar, in scalars: [Unicode.Scalar], from index: Int) -> Int {
        var i = index
        while i < scalars.count {
            if scalars[i] == target { return i + 1 }
            i += 1
        }
        return scalars.count
    }

    /// After `-->` (or `--!>`), or the end. `<!-->` and `<!--->` close at once, as in HTML5.
    private static func endOfComment(_ scalars: [Unicode.Scalar], from index: Int) -> Int {
        if index < scalars.count, scalars[index] == ">" { return index + 1 }
        if matches(scalars, at: index, "->") { return index + 2 }
        var i = index
        while i < scalars.count {
            if matches(scalars, at: i, "-->") { return i + 3 }
            if matches(scalars, at: i, "--!>") { return i + 4 }
            i += 1
        }
        return scalars.count
    }

    /// The end of a raw-text element's content: the next `</name` followed by whitespace, `/`
    /// or `>`, case-insensitively. Returns where the content stops and where scanning resumes.
    private static func endOfRawText(_ scalars: [Unicode.Scalar], element: String, from index: Int) -> (contentEnd: Int, next: Int) {
        var i = index
        while i < scalars.count {
            if scalars[i] == "<", i + 1 < scalars.count, scalars[i + 1] == "/", matchesInsensitive(scalars, at: i + 2, element) {
                let after = i + 2 + element.unicodeScalars.count
                if after >= scalars.count || isSpace(scalars[after]) || scalars[after] == "/" || scalars[after] == ">" {
                    return (i, Self.after(">", in: scalars, from: after))
                }
            }
            i += 1
        }
        return (scalars.count, scalars.count)
    }
}

/// HTML character references (`&amp;`, `&#233;`, `&#xE9;`). The named set covers what mail
/// uses; an unknown name stays as written, which is how browsers treat it too.
public enum CharacterReferences {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "sbquo": "‚", "bdquo": "„", "laquo": "«", "raquo": "»", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "middot": "·", "bull": "•", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "frac12": "½",
        "frac14": "¼", "frac34": "¾", "sect": "§", "para": "¶", "shy": "\u{00AD}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "lrm": "\u{200E}", "rlm": "\u{200F}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é",
        "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à", "acirc": "â", "atilde": "ã",
        "aring": "å", "oacute": "ó", "ograve": "ò", "ocirc": "ô", "otilde": "õ", "uacute": "ú", "ugrave": "ù",
        "ucirc": "û", "iacute": "í", "igrave": "ì", "icirc": "î", "iuml": "ï", "ccedil": "ç", "ntilde": "ñ",
        "Eacute": "É", "Egrave": "È", "Aacute": "Á", "Agrave": "À", "Oacute": "Ó", "Uacute": "Ú", "Ccedil": "Ç",
        "Ntilde": "Ñ", "oslash": "ø", "Oslash": "Ø", "aelig": "æ", "AElig": "Æ", "iexcl": "¡", "iquest": "¿",
        "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "check": "✓", "hearts": "♥", "star": "☆",
    ]

    public static func decode(_ text: String, inAttribute: Bool) -> String {
        guard text.contains("&") else { return text }
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "&" else { out.append(scalars[i]); i += 1; continue }
            var j = i + 1
            if j < scalars.count, scalars[j] == "#" {
                j += 1
                var hex = false
                if j < scalars.count, scalars[j] == "x" || scalars[j] == "X" { hex = true; j += 1 }
                let digitsStart = j
                while j < scalars.count, j - digitsStart < 8,
                      hex ? scalars[j].properties.isASCIIHexDigit : (scalars[j] >= "0" && scalars[j] <= "9") { j += 1 }
                guard j > digitsStart else { out.append(scalars[i]); i += 1; continue }
                let digits = String(String.UnicodeScalarView(scalars[digitsStart..<j]))
                let value = UInt32(digits, radix: hex ? 16 : 10) ?? 0xFFFD
                if j < scalars.count, scalars[j] == ";" { j += 1 }
                // NUL, surrogates and out-of-range values become U+FFFD, as in HTML5.
                let scalar = (value == 0 || value > 0x10FFFF || (0xD800...0xDFFF).contains(value)) ? nil : Unicode.Scalar(value)
                out.append(scalar ?? "\u{FFFD}")
                i = j
                continue
            }
            var name = String.UnicodeScalarView()
            while j < scalars.count, j - i <= 10, scalars[j].properties.isAlphabetic || (scalars[j] >= "0" && scalars[j] <= "9") {
                name.append(scalars[j])
                j += 1
            }
            let hasSemicolon = j < scalars.count && scalars[j] == ";"
            // In attributes, "&name=" without ";" is left alone (HTML5), so query strings survive.
            if let replacement = named[String(name)], hasSemicolon || !inAttribute {
                out.append(contentsOf: replacement.unicodeScalars)
                i = hasSemicolon ? j + 1 : j
            } else {
                out.append(scalars[i])
                i += 1
            }
        }
        return String(out)
    }

    /// Escapes text for an HTML text node or a double-quoted attribute value.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
