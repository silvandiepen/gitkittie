import Foundation

/// Turns the composer's Markdown into the HTML part of an outgoing message.
///
/// Safe by construction: every character the person typed is HTML-escaped before any Markdown
/// is applied, so raw HTML in the text (or in a quoted message) is shown as text, never sent as
/// markup. Links keep only `http`, `https` and `mailto`. No scripts, styles from the text,
/// images or remote content are ever produced.
///
/// The subset is what mail needs: paragraphs (a line break stays a line break), headings,
/// emphasis, strong, inline code, fenced code, block quotes (nested, for quoted replies),
/// bulleted and numbered lists, rules, links and autolinks.
public enum MarkdownHTML {
    public static func document(_ markdown: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"></head>
        <body style="font-family: -apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 14px; line-height: 1.5;">
        \(fragment(markdown))</body></html>

        """
    }

    public static func fragment(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return blocks(lines[...], depth: 0)
    }

    // MARK: - Blocks

    /// Quotes nest at most this deep in the HTML; deeper levels render flat.
    static let maximumDepth = 24

    private static func blocks(_ lines: ArraySlice<String>, depth: Int) -> String {
        var html = ""
        var index = lines.startIndex
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + paragraph.map { line in
                // Two trailing spaces or a backslash are Markdown's hard break; every line
                // break is kept anyway, as people expect in mail.
                var text = line
                while text.hasSuffix(" ") { text.removeLast() }
                if text.hasSuffix("\\") { text.removeLast() }
                return inline(text)
            }.joined(separator: "<br>\n") + "</p>\n"
            paragraph = []
        }

        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.endIndex, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index = min(index + 1, lines.endIndex)
                html += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }

            // Block quote: a run of lines starting with ">".
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.endIndex {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var rest = candidate.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    index += 1
                }
                if depth < maximumDepth {
                    html += "<blockquote style=\"margin: 0 0 0 0.8ex; border-left: 1px solid #ccc; padding-left: 1ex;\">\n"
                        + blocks(quoted[...], depth: depth + 1) + "</blockquote>\n"
                } else {
                    html += "<p>" + quoted.map(inline).joined(separator: "<br>\n") + "</p>\n"
                }
                continue
            }

            // Heading.
            if let level = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                html += "<h\(level)>" + inline(text) + "</h\(level)>\n"
                index += 1
                continue
            }

            // Rule.
            if isRule(trimmed) {
                flushParagraph()
                html += "<hr>\n"
                index += 1
                continue
            }

            // Lists: a run of items of one kind; indented lines continue the item.
            if let first = listItem(trimmed) {
                flushParagraph()
                let ordered = first.ordered
                var items: [[String]] = []
                while index < lines.endIndex {
                    let candidate = lines[index]
                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                    if let item = listItem(candidateTrimmed), item.ordered == ordered, !candidate.hasPrefix("  ") {
                        items.append([item.text])
                    } else if !candidateTrimmed.isEmpty, candidate.hasPrefix(" "), !items.isEmpty {
                        items[items.count - 1].append(candidateTrimmed)
                    } else {
                        break
                    }
                    index += 1
                }
                let tag = ordered ? "ol" : "ul"
                html += "<\(tag)>\n" + items.map { "<li>" + $0.map(inline).joined(separator: "<br>\n") + "</li>\n" }.joined() + "</\(tag)>\n"
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return html
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let after = line.dropFirst(hashes)
        return after.isEmpty || after.hasPrefix(" ") ? hashes : nil
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        if (1...9).contains(digits.count) {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (true, String(rest.dropFirst(2))) }
        }
        return nil
    }

    // MARK: - Inline

    static func inline(_ text: String) -> String {
        // Code spans first: nothing inside them is Markdown.
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "`") else { break }
            out += spans(String(rest[..<open]))
            out += "<code>" + escape(String(rest[afterOpen..<close])) + "</code>"
            rest = rest[rest.index(after: close)...]
        }
        out += spans(String(rest))
        return out
    }

    /// Links, autolinks and emphasis on text that is escaped first.
    private static func spans(_ raw: String) -> String {
        // Backslash escapes: keep the character, drop its Markdown meaning.
        var protected: [String] = []
        var text = ""
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.peekable(), next.isASCII, next.isPunctuation || next.isSymbol {
                _ = iterator.next()
                protected.append(escape(String(next)))
                text += "\u{E000}\(protected.count - 1)\u{E001}"
            } else {
                text.append(character)
            }
        }

        var html = escape(text)

        // [text](url)
        // A finished link is set aside like an escape, so emphasis never reaches into its URL.
        func setAside(_ html: String) -> String {
            protected.append(html)
            return "\u{E000}\(protected.count - 1)\u{E001}"
        }
        html = replace(html, pattern: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#) { groups in
            let label = groups[1], url = groups[2]
            guard isAllowedURL(url) else { return label }
            return setAside("<a href=\"\(url)\">\(label)</a>")
        }
        // <https://…> and <mailto:…>, escaped by now as &lt;…&gt;
        html = replace(html, pattern: #"&lt;((?:https?://|mailto:)[^\s&]+(?:&amp;[^\s&]+)*)&gt;"#) { groups in
            setAside("<a href=\"\(groups[1])\">\(groups[1])</a>")
        }
        html = replace(html, pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#) { "<strong>\($0[1])</strong>" }
        html = replace(html, pattern: #"(?<![\w])__(?=\S)(.+?)(?<=\S)__(?![\w])"#) { "<strong>\($0[1])</strong>" }
        html = replace(html, pattern: #"(?<![\*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\*\w])"#) { "<em>\($0[1])</em>" }
        html = replace(html, pattern: #"(?<![\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w])"#) { "<em>\($0[1])</em>" }
        html = replace(html, pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#) { "<del>\($0[1])</del>" }

        // Put the escaped characters and links back (a link's label may hold an escape, so
        // twice is enough).
        for _ in 0..<2 {
            html = replace(html, pattern: "\u{E000}(\\d+)\u{E001}") { groups in
                Int(groups[1]).flatMap { protected.indices.contains($0) ? protected[$0] : nil } ?? ""
            }
        }
        return html
    }

    /// Only web and mail links. The URL is already HTML-escaped, so it cannot leave the
    /// attribute; the scheme check stops `javascript:`, `data:`, `file:` and the like.
    static func isAllowedURL(_ escapedURL: String) -> Bool {
        let lowered = escapedURL.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://") || lowered.hasPrefix("mailto:")
    }

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
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

    private static func replace(_ text: String, pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            out += transform(groups)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

private extension String.Iterator {
    /// The next character without consuming it.
    func peekable() -> Character? {
        var copy = self
        return copy.next()
    }
}
