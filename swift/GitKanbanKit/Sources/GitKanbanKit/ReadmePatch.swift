import Foundation
import GitKittieKit

/// Changing parts of a board's README without rewriting the rest. The settings window
/// knows lanes, priorities, members, types and epics; a README can hold much more (text,
/// linked docs, keys of other tools), and all of that has to survive a save.
enum ReadmePatch {
    /// A top-level key of the frontmatter with the lines that belong to it.
    struct Block: Equatable {
        var key: String
        var lines: [String]
    }

    /// The frontmatter as top-level blocks, in order. Lines before the first key (comments)
    /// are a block with an empty key.
    static func blocks(_ frontmatter: String) -> [Block] {
        var result: [Block] = []
        for line in frontmatter.components(separatedBy: "\n") {
            let isTopLevelKey: Bool = {
                guard let first = line.first, !first.isWhitespace, first != "-", first != "#" else { return false }
                return line.contains(":")
            }()
            if isTopLevelKey, let colon = line.firstIndex(of: ":") {
                result.append(Block(key: line[..<colon].trimmingCharacters(in: .whitespaces), lines: [line]))
            } else if result.isEmpty {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { result.append(Block(key: "", lines: [line])) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                result[result.count - 1].lines.append(line)
            }
        }
        return result
    }

    /// `original` with the blocks of `keys` taken from `rendered` (a README rendered from
    /// the settings). A key `rendered` does not have is removed; one `original` does not
    /// have is added at the end. Every other line, and the text under the frontmatter, stay.
    /// `unchanged` names keys to leave exactly as they are in `original`.
    static func apply(_ rendered: String, to original: String, keys: [String], unchanged: Set<String> = []) -> String {
        let (oldFrontmatter, body) = BoardMarkdown.splitFrontmatter(original)
        let new = blocks(BoardMarkdown.splitFrontmatter(rendered).frontmatter ?? "")
        var result: [Block] = []
        var placed = Set<String>()
        for block in blocks(oldFrontmatter ?? "") {
            guard keys.contains(block.key), !unchanged.contains(block.key) else { result.append(block); continue }
            if let replacement = new.first(where: { $0.key == block.key }) { result.append(replacement) }
            placed.insert(block.key)
        }
        let present = Set(result.map(\.key)).union(placed)
        for key in keys where !present.contains(key) && !unchanged.contains(key) {
            if let added = new.first(where: { $0.key == key }) { result.append(added) }
        }
        if result.isEmpty { return rendered }
        let frontmatter = result.flatMap(\.lines).joined(separator: "\n")
        return "---\n\(frontmatter)\n---\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }
}
