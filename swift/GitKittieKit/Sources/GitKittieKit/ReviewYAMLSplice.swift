import Foundation
import Yams

// Writing a changed `review.md` frontmatter back with the smallest change to its text.
//
// Review requests are written by hand, by agents and by the app, each in its own YAML style
// (flow lists, quoted notes, indented or flush sequences, comments). Serializing the whole
// tree again would restyle every line of a hand-written request on the first decision. So
// the new tree is laid over the old text: a key, list entry or nested mapping whose value is
// the same as before keeps its exact lines, and only what changed is serialized, at the
// indentation the old text used there.
//
// The result is checked by parsing it again: when it does not read back as the new tree
// (an unusual layout the splitter does not understand), the whole frontmatter is serialized
// instead, so the splice can only ever lose formatting, never data.

enum ReviewYAMLSplice {
    /// The frontmatter (without fences or a trailing newline) for `map`, reusing the lines of
    /// `text`, which holds `original`.
    static func render(_ map: Node.Mapping, original: Node.Mapping, text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        if let spliced = mapping(map, original: original, lines: lines[...], indent: 0) {
            let candidate = spliced.joined(separator: "\n")
            if let reread = try? Yams.compose(yaml: candidate), same(reread, .mapping(map)) { return candidate }
        }
        let yaml = try Yams.serialize(node: .mapping(map), width: -1, allowUnicode: true)
        return yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
    }

    /// The same tree as far as a reader of `review.md` can tell: the same text in every scalar
    /// (a quoted `'2026-11-30T10:00:00Z'` and a plain one carry different tags, but read the same).
    static func same(_ a: Node, _ b: Node) -> Bool {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)):
            return x.string == y.string
        case let (.mapping(x), .mapping(y)):
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { same($0.key, $1.key) && same($0.value, $1.value) }
        case let (.sequence(x), .sequence(y)):
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { same($0, $1) }
        case let (.alias(x), .alias(y)):
            return x == y
        default:
            return false
        }
    }

    // MARK: Mappings

    private struct Block {
        var key: String
        var lines: ArraySlice<String>
    }

    /// A block mapping's lines at `indent`, laid over with `new`; `nil` when the text cannot
    /// be split into the old mapping's keys.
    private static func mapping(_ new: Node.Mapping, original: Node.Mapping, lines: ArraySlice<String>, indent: Int) -> [String]? {
        guard let (leading, blocks) = split(lines, indent: indent) else { return nil }
        let oldKeys = original.keys.map { $0.string }
        guard blocks.map(\.key) == oldKeys.map({ $0 ?? "" }), !oldKeys.contains(nil) else { return nil }
        var out = Array(leading)
        for (keyNode, value) in new {
            guard let key = keyNode.string else { return nil }
            if let index = blocks.firstIndex(where: { $0.key == key }), let old = original[key] {
                if value == old { out += blocks[index].lines; continue }
                let (body, trailer) = peel(blocks[index].lines)
                guard let lines = pair(key, value, old: old, block: body, indent: indent) else { return nil }
                out += lines + trailer
            } else {
                guard let lines = fresh(key, value, indent: indent) else { return nil }
                out += lines
            }
        }
        return out
    }

    private static func pair(_ key: String, _ value: Node, old: Node, block: ArraySlice<String>, indent: Int) -> [String]? {
        if value == old { return Array(block) }
        guard let first = block.first, valueText(first).isEmpty else { return fresh(key, value, indent: indent) }
        let children = block.dropFirst()
        if let newMap = value.mapping, let oldMap = old.mapping, let childIndent = firstIndent(children), childIndent > indent,
           let lines = mapping(newMap, original: oldMap, lines: children, indent: childIndent) {
            return [first] + lines
        }
        if let newSeq = value.sequence, let oldSeq = old.sequence, let seqIndent = firstIndent(children), seqIndent >= indent,
           let lines = sequence(newSeq, original: oldSeq, lines: children, indent: seqIndent) {
            return [first] + lines
        }
        return fresh(key, value, indent: indent)
    }

    /// Split a block mapping at `indent` into the lines before its first key and one block per key.
    private static func split(_ lines: ArraySlice<String>, indent: Int) -> (ArraySlice<String>, [Block])? {
        var blocks: [Block] = []
        var start: Int?
        var key = ""
        var leadingEnd = lines.endIndex
        for index in lines.indices {
            guard let found = keyAt(lines[index], indent: indent) else { continue }
            if let start { blocks.append(Block(key: key, lines: lines[start..<index])) } else { leadingEnd = index }
            start = index
            key = found
        }
        guard let start else { return lines.allSatisfy(isBlankOrComment) ? (lines, []) : nil }
        blocks.append(Block(key: key, lines: lines[start..<lines.endIndex]))
        let leading = lines[lines.startIndex..<leadingEnd]
        guard leading.allSatisfy(isBlankOrComment) else { return nil }
        return (leading, blocks)
    }

    private static let keyPattern = try! NSRegularExpression(pattern: #"^("([^"\\]*)"|'([^']*)'|([^\s#'"\-?:,\[\]{}][^:]*?|-[^\s:][^:]*?))\s*:(\s|$)"#)

    /// The key a line starts at exactly `indent`, or `nil`.
    private static func keyAt(_ line: String, indent: Int) -> String? {
        guard line.prefix(indent).allSatisfy({ $0 == " " }), line.count > indent else { return nil }
        let rest = String(line.dropFirst(indent))
        guard let first = rest.first, first != " ", first != "#" else { return nil }
        let range = NSRange(rest.startIndex..., in: rest)
        guard let match = keyPattern.firstMatch(in: rest, range: range) else { return nil }
        for group in [2, 3, 4] {
            if let r = Range(match.range(at: group), in: rest) { return String(rest[r]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// What follows `key:` on a key line, without a comment.
    private static func valueText(_ line: String) -> String {
        guard let colon = colonIndex(line) else { return "" }
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value = "" }
        return value
    }

    private static func colonIndex(_ line: String) -> String.Index? {
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" { return index }
            }
            index = line.index(after: index)
        }
        return nil
    }

    // MARK: Sequences

    private static func sequence(_ new: Node.Sequence, original: Node.Sequence, lines: ArraySlice<String>, indent: Int) -> [String]? {
        var entries: [ArraySlice<String>] = []
        var start: Int?
        var leadingEnd = lines.endIndex
        for index in lines.indices where isEntryStart(lines[index], indent: indent) {
            if let start { entries.append(lines[start..<index]) } else { leadingEnd = index }
            start = index
        }
        if let start { entries.append(lines[start..<lines.endIndex]) }
        let leading = lines[lines.startIndex..<leadingEnd]
        guard entries.count == original.count, leading.allSatisfy(isBlankOrComment) else { return nil }
        let old = Array(original)
        var used = Set<Int>()
        var out = Array(leading)
        for (offset, value) in new.enumerated() {
            if let same = old.indices.first(where: { !used.contains($0) && old[$0] == value && ($0 == offset || id(old[$0]) != nil) })
                ?? old.indices.first(where: { !used.contains($0) && old[$0] == value }) {
                used.insert(same)
                out += entries[same]
                continue
            }
            let match = id(value).flatMap { wanted in old.indices.first { !used.contains($0) && id(old[$0]) == wanted } }
                ?? (old.indices.contains(offset) && !used.contains(offset) && id(value) == nil ? offset : nil)
            let (body, trailer) = match.map { peel(entries[$0]) } ?? ([], [])
            if let match, let lines = entry(value, old: old[match], block: body, indent: indent) {
                used.insert(match)
                out += lines + trailer
            } else {
                guard let lines = freshEntry(value, indent: indent) else { return nil }
                out += lines
            }
        }
        return out
    }

    private static func id(_ node: Node) -> String? { node.mapping?["id"]?.string }

    private static func isEntryStart(_ line: String, indent: Int) -> Bool {
        guard line.prefix(indent).allSatisfy({ $0 == " " }) else { return false }
        let rest = line.dropFirst(indent)
        return rest == "-" || rest.hasPrefix("- ")
    }

    /// One list entry laid over its old lines: a mapping whose first key sits on the dash line
    /// is spliced key by key; anything else is written anew.
    private static func entry(_ value: Node, old: Node, block: ArraySlice<String>, indent: Int) -> [String]? {
        guard let newMap = value.mapping, let oldMap = old.mapping, let first = block.first,
              first.dropFirst(indent).hasPrefix("- "), first.dropFirst(indent + 2).first.map({ $0 != " " && $0 != "{" && $0 != "#" }) == true else {
            return freshEntry(value, indent: indent)
        }
        let pad = String(repeating: " ", count: indent + 2)
        var lines = Array(block)
        lines[0] = pad + String(first.dropFirst(indent + 2))
        guard var result = mapping(newMap, original: oldMap, lines: lines[...], indent: indent + 2),
              let head = result.first, head.hasPrefix(pad), head.dropFirst(indent + 2).first.map({ $0 != " " }) == true else {
            return freshEntry(value, indent: indent)
        }
        result[0] = String(repeating: " ", count: indent) + "- " + String(head.dropFirst(indent + 2))
        return result
    }

    // MARK: Fresh text

    private static func fresh(_ key: String, _ value: Node, indent: Int) -> [String]? {
        serialize(.mapping(Node.Mapping([(Node(key), value)])), indent: indent)
    }

    private static func freshEntry(_ value: Node, indent: Int) -> [String]? {
        serialize(.sequence(Node.Sequence([value])), indent: indent)
    }

    private static func serialize(_ node: Node, indent: Int) -> [String]? {
        guard var yaml = try? Yams.serialize(node: node, width: -1, allowUnicode: true) else { return nil }
        if yaml.hasSuffix("\n") { yaml.removeLast() }
        let pad = String(repeating: " ", count: indent)
        return yaml.components(separatedBy: "\n").map { $0.isEmpty ? $0 : pad + $0 }
    }

    // MARK: Lines

    /// A block without the blank and comment lines at its end, and those lines: they belong
    /// between this block and the next, and stay there when this block is written anew.
    private static func peel(_ lines: ArraySlice<String>) -> (ArraySlice<String>, ArraySlice<String>) {
        var end = lines.endIndex
        while end > lines.startIndex + 1, isBlankOrComment(lines[end - 1]) { end -= 1 }
        return (lines[lines.startIndex..<end], lines[end..<lines.endIndex])
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// The indentation of the first line in `lines` that holds something.
    private static func firstIndent(_ lines: ArraySlice<String>) -> Int? {
        lines.first { !isBlankOrComment($0) }.map { $0.prefix { $0 == " " }.count }
    }
}
