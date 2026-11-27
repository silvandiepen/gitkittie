import Foundation

/// Markdown taken apart into the blocks a page is drawn from: headings, paragraphs, code,
/// lists with their checkboxes, note boxes, tables and pictures. Inline marks (bold, links,
/// code) stay in each block's text for the view to style.
public enum MarkdownBlocks {

    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(language: String, text: String)
        case list([Item])
        /// A quote; with a kind (`NOTE`, `WARNING`, …) when it starts with `[!KIND]`.
        case quote(kind: String?, text: String)
        case table(header: [String], rows: [[String]])
        case rule
        /// Pictures (`![alt](file)`, also inside a link) on lines of their own, side by side.
        /// A picture in a line of text is taken out of it and shown after that paragraph.
        case images([Image])
    }

    /// A picture: its alt text, where it is (relative to the document, or a URL) and, for
    /// `[![alt](small.png)](large.png)`, what it links to.
    public struct Image: Equatable, Sendable, Hashable {
        public var alt: String
        public var source: String
        public var link: String?
        public init(alt: String, source: String, link: String? = nil) {
            self.alt = alt; self.source = source; self.link = link
        }
    }

    public struct Item: Equatable, Sendable {
        public var indent: Int
        /// `1.` for a numbered item, nil for a bullet.
        public var number: String?
        /// Checked or not, for a task item; nil for a plain one.
        public var checked: Bool?
        /// Which checkbox of the whole text this is, counted from 0 (see `AppModel.toggleCheckbox`).
        public var checkIndex: Int?
        public var text: String
    }

    public static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var checkboxes = 0
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }

        /// Pictures go after what is above them; pictures on consecutive lines form one row.
        func appendImages(_ images: [Image]) {
            if case .images(let earlier)? = blocks.last {
                blocks[blocks.count - 1] = .images(earlier + images)
            } else {
                blocks.append(.images(images))
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                index += 1
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty { flush(); index += 1; continue }

            if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            if isRule(trimmed) { flush(); blocks.append(.rule); index += 1; continue }

            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(lines[index].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                var kind: String?
                if let first = quoted.first, first.hasPrefix("[!"), let close = first.firstIndex(of: "]") {
                    kind = String(first[first.index(first.startIndex, offsetBy: 2)..<close]).uppercased()
                    let rest = first[first.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    quoted.removeFirst()
                    if !rest.isEmpty { quoted.insert(rest, at: 0) }
                }
                blocks.append(.quote(kind: kind, text: quoted.joined(separator: " ").trimmingCharacters(in: .whitespaces)))
                continue
            }

            if trimmed.contains("|"), index + 1 < lines.count, isTableRule(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index])); index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if var item = listItem(line) {
                flush()
                var items: [Item] = []
                while true {
                    if item.checked != nil {
                        // Counted as the checkbox toggle counts them: bullets only.
                        if item.number == nil { item.checkIndex = checkboxes; checkboxes += 1 } else { item.checked = nil; item.text = "[ ] " + item.text }
                    }
                    items.append(item)
                    index += 1
                    // Lines under an item that are not items themselves belong to it.
                    while index < lines.count {
                        let next = lines[index]
                        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                        if nextTrimmed.isEmpty || listItem(next) != nil || next.first?.isWhitespace != true
                            || nextTrimmed.hasPrefix("```") || nextTrimmed.hasPrefix("~~~") { break }
                        items[items.count - 1].text += " " + nextTrimmed
                        index += 1
                    }
                    // A blank line between two items does not end the list.
                    var look = index
                    while look < lines.count, lines[look].trimmingCharacters(in: .whitespaces).isEmpty { look += 1 }
                    guard look < lines.count, let next = listItem(lines[look]) else { break }
                    item = next
                    index = look
                }
                blocks.append(.list(items))
                continue
            }

            let (text, images) = extractImages(trimmed)
            if images.isEmpty {
                paragraph.append(trimmed)
            } else {
                if !text.isEmpty { paragraph.append(text) }
                flush()
                appendImages(images)
            }
            index += 1
        }
        flush()
        return blocks
    }

    /// The text of a line with its pictures taken out, and the pictures. Handles `![alt](src)`,
    /// `![alt](src "title")` and a picture inside a link, `[![alt](src)](href)`.
    public static func extractImages(_ line: String) -> (text: String, images: [Image]) {
        guard line.contains("![") else { return (line, []) }
        let chars = Array(line)
        var text = ""
        var images: [Image] = []
        var i = 0

        /// `![alt](src)` starting at `start`: the picture and the index after it.
        func image(at start: Int) -> (Image, Int)? {
            guard start + 1 < chars.count, chars[start] == "!", chars[start + 1] == "[" else { return nil }
            guard let closeAlt = matching(chars, from: start + 1, open: "[", close: "]"),
                  closeAlt + 1 < chars.count, chars[closeAlt + 1] == "(",
                  let closeSrc = matching(chars, from: closeAlt + 1, open: "(", close: ")") else { return nil }
            let alt = String(chars[(start + 2)..<closeAlt])
            let target = destination(String(chars[(closeAlt + 2)..<closeSrc]))
            guard !target.isEmpty else { return nil }
            return (Image(alt: alt, source: target), closeSrc + 1)
        }

        while i < chars.count {
            // A linked picture: [![alt](src)](href)
            if chars[i] == "[", let (picture, after) = image(at: i + 1), after < chars.count, chars[after] == "]",
               after + 1 < chars.count, chars[after + 1] == "(",
               let closeLink = matching(chars, from: after + 1, open: "(", close: ")") {
                var linked = picture
                linked.link = destination(String(chars[(after + 2)..<closeLink]))
                images.append(linked)
                i = closeLink + 1
                continue
            }
            if let (picture, after) = image(at: i) {
                images.append(picture)
                i = after
                continue
            }
            text.append(chars[i])
            i += 1
        }
        let rest = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return (rest, images)
    }

    /// The index of the bracket that closes the one at `from`, counting nested pairs.
    private static func matching(_ chars: [Character], from: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        var i = from
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == open { depth += 1 }
            if chars[i] == close { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return nil
    }

    /// A link destination without its optional title and angle brackets.
    private static func destination(_ raw: String) -> String {
        var target = raw.trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("<"), let end = target.firstIndex(of: ">") {
            return String(target[target.index(after: target.startIndex)..<end])
        }
        if let space = target.firstIndex(of: " ") { target = String(target[..<space]) }
        return target
    }

    // MARK: Text as it is shown

    /// Inline Markdown (bold, emphasis, code, links) parsed as the views draw it. Falls back
    /// to the text itself when it is not valid Markdown.
    public static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// The words a reader sees for these blocks, one block per line: what is left of the
    /// Markdown once it is drawn. Pictures read as their alt text in brackets.
    public static func renderedText(_ blocks: [Block]) -> String {
        func plain(_ text: String) -> String { String(inline(text).characters) }
        return blocks.map { block -> String in
            switch block {
            case .heading(_, let text), .paragraph(let text): return plain(text)
            case .code(_, let text): return text
            case .list(let items): return items.map { plain($0.text) }.joined(separator: "\n")
            case .quote(_, let text): return plain(text)
            case .table(let header, let rows): return ([header] + rows).map { $0.map(plain).joined(separator: "\t") }.joined(separator: "\n")
            case .rule: return ""
            case .images(let images): return images.map { "[\($0.alt)]" }.joined(separator: " ")
            }
        }.joined(separator: "\n")
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> Item? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        var rest = Substring(line.drop { $0 == " " || $0 == "\t" })
        var number: String?
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            rest = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isNumber }
            let after = rest.dropFirst(digits.count)
            guard !digits.isEmpty, digits.count <= 4, let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
            number = String(digits) + "."
            rest = after.dropFirst(2)
        }
        rest = rest.drop { $0 == " " }
        var checked: Bool?
        if rest.hasPrefix("[ ] ") || rest == "[ ]" { checked = false; rest = rest.dropFirst(3) }
        else if rest.lowercased().hasPrefix("[x] ") || rest.lowercased() == "[x]" { checked = true; rest = rest.dropFirst(3) }
        return Item(indent: indent, number: number, checked: checked, checkIndex: nil, text: rest.trimmingCharacters(in: .whitespaces))
    }
}
