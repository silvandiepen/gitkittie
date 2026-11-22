import Foundation

/// Markdown taken apart into the blocks a page is drawn from: headings, paragraphs, code,
/// lists with their checkboxes, note boxes, tables. Inline marks (bold, links, code) stay
/// in each block's text for the view to style.
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

            paragraph.append(trimmed)
            index += 1
        }
        flush()
        return blocks
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
