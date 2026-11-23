import Foundation

/// Which changed lines of a diff are chosen: per hunk (`GitHunk.id`), the indexes into that
/// hunk's `lines`. Only `+` and `-` lines count; an index of a context line is ignored.
public struct GitChangeSelection: Sendable, Equatable {
    public var lines: [String: Set<Int>]

    public init(lines: [String: Set<Int>] = [:]) {
        self.lines = lines
    }

    public var isEmpty: Bool { lines.values.allSatisfy(\.isEmpty) }

    /// How many changed lines are chosen across `diffs`.
    public func count(in diffs: [GitFileDiff]) -> Int {
        diffs.flatMap(\.hunks).reduce(0) { total, hunk in
            total + (lines[hunk.id] ?? []).filter { GitPatchBuilder.isChange(hunk.lines, at: $0) }.count
        }
    }

    public func contains(_ hunk: GitHunk, line index: Int) -> Bool {
        lines[hunk.id]?.contains(index) ?? false
    }

    /// Every changed line of the hunk chosen.
    public func containsAll(of hunk: GitHunk) -> Bool {
        let changes = GitPatchBuilder.changeIndexes(of: hunk)
        return !changes.isEmpty && changes.isSubset(of: lines[hunk.id] ?? [])
    }

    public mutating func toggle(_ hunk: GitHunk, line index: Int) {
        guard GitPatchBuilder.isChange(hunk.lines, at: index) else { return }
        var chosen = lines[hunk.id] ?? []
        if chosen.contains(index) { chosen.remove(index) } else { chosen.insert(index) }
        lines[hunk.id] = chosen
    }

    /// Choose the whole hunk, or clear it when it is already wholly chosen.
    public mutating func toggle(_ hunk: GitHunk) {
        lines[hunk.id] = containsAll(of: hunk) ? [] : GitPatchBuilder.changeIndexes(of: hunk)
    }

    /// Choose every change in the file, or clear it when it is already wholly chosen.
    public mutating func toggle(_ file: GitFileDiff) {
        let all = !file.hunks.isEmpty && file.hunks.allSatisfy(containsAll(of:))
        for hunk in file.hunks {
            lines[hunk.id] = all ? [] : GitPatchBuilder.changeIndexes(of: hunk)
        }
    }

    public mutating func clear() { lines = [:] }
}

/// Builds a patch that carries only the chosen lines of a commit's diff, in either direction.
///
/// Forward (pick): a chosen line is applied as the commit made it; an unchosen removal stays
/// as an unchanged line and an unchosen addition is left out. Reverse (undo): the same, with
/// the commit's additions and removals swapped. The result is a set of small hunks with three
/// lines of context, so it applies to a file that has changed elsewhere since.
public enum GitPatchBuilder {
    static let context = 3

    public static func isChange(_ lines: [String], at index: Int) -> Bool {
        guard lines.indices.contains(index) else { return false }
        return lines[index].hasPrefix("+") || lines[index].hasPrefix("-")
    }

    public static func changeIndexes(of hunk: GitHunk) -> Set<Int> {
        Set(hunk.lines.indices.filter { isChange(hunk.lines, at: $0) })
    }

    public static func patch(for diffs: [GitFileDiff], selection: GitChangeSelection, reverse: Bool) -> String {
        diffs.map { patch(for: $0, selection: selection, reverse: reverse) }.joined()
    }

    /// One file's part of the patch; empty when nothing in it is chosen.
    public static func patch(for file: GitFileDiff, selection: GitChangeSelection, reverse: Bool) -> String {
        var hunks: [String] = []
        var everyChangeChosen = true
        for hunk in file.hunks {
            let chosen = selection.lines[hunk.id] ?? []
            if !changeIndexes(of: hunk).isSubset(of: chosen) { everyChangeChosen = false }
            hunks += build(hunk, chosen: chosen, reverse: reverse)
        }
        guard !hunks.isEmpty else { return "" }

        // Whether the file exists before and after this patch.
        let createsFile = reverse ? file.isDeletedFile : file.isNewFile
        let removesFile = (reverse ? file.isNewFile : file.isDeletedFile) && everyChangeChosen
        let path = file.path
        var header = ["diff --git a/\(path) b/\(path)"]
        if createsFile {
            header += ["new file mode 100644", "--- /dev/null", "+++ b/\(path)"]
        } else if removesFile {
            header += ["deleted file mode 100644", "--- a/\(path)", "+++ /dev/null"]
        } else {
            header += ["--- a/\(path)", "+++ b/\(path)"]
        }
        return (header + hunks).joined(separator: "\n") + "\n"
    }

    private struct Line {
        enum Kind { case context, removal, addition }
        var kind: Kind
        var text: String
        /// A `\ No newline at end of file` marker that belongs to this line.
        var noNewline = false
        var fromNumber = 0
        var toNumber = 0
    }

    private static func build(_ hunk: GitHunk, chosen: Set<Int>, reverse: Bool) -> [String] {
        guard !chosen.isDisjoint(with: changeIndexes(of: hunk)) else { return [] }
        let (oldStart, newStart) = starts(of: hunk.header)

        // The hunk's lines as the patch will carry them.
        var lines: [Line] = []
        // Whether the line before a `\ No newline` marker made it into the patch: the marker
        // belongs to that line only.
        var previousKept = false
        for (index, raw) in hunk.lines.enumerated() {
            if raw.hasPrefix("\\") {
                if previousKept { lines[lines.count - 1].noNewline = true }
                continue
            }
            // A real unchanged empty line is " ". A bare "" is the end of the patch text that
            // the parser keeps after the last newline; it is not a line of the file.
            if raw.isEmpty { continue }
            let countBefore = lines.count
            defer { previousKept = lines.count > countBefore }
            let text = String(raw.dropFirst())
            let isChosen = chosen.contains(index)
            switch (raw.first, reverse) {
            case (" ", _):
                lines.append(Line(kind: .context, text: text))
            case ("-", false):
                lines.append(Line(kind: isChosen ? .removal : .context, text: text))
            case ("+", false):
                if isChosen { lines.append(Line(kind: .addition, text: text)) }
            case ("+", true):
                lines.append(Line(kind: isChosen ? .removal : .context, text: text))
            case ("-", true):
                if isChosen { lines.append(Line(kind: .addition, text: text)) }
            default:
                lines.append(Line(kind: .context, text: text))
            }
        }

        // Number each line in the file the patch applies to ("from") and the result ("to").
        var from = reverse ? newStart : oldStart
        var to = from
        for index in lines.indices {
            lines[index].fromNumber = from
            lines[index].toNumber = to
            switch lines[index].kind {
            case .context: from += 1; to += 1
            case .removal: from += 1
            case .addition: to += 1
            }
        }

        // Cut into hunks: each run of changes with up to three unchanged lines either side.
        let changes = lines.indices.filter { lines[$0].kind != .context }
        guard let first = changes.first else { return [] }
        var groups: [(Int, Int)] = []
        var start = first
        var end = first
        for index in changes.dropFirst() {
            if index - end > context * 2 { groups.append((start, end)); start = index }
            end = index
        }
        groups.append((start, end))

        return groups.flatMap { group -> [String] in
            let lower = max(0, group.0 - context)
            let upper = min(lines.count - 1, group.1 + context)
            let slice = lines[lower...upper]
            let fromCount = slice.filter { $0.kind != .addition }.count
            let toCount = slice.filter { $0.kind != .removal }.count
            let fromStart = fromCount == 0 ? max(0, slice.first!.fromNumber - 1) : slice.first!.fromNumber
            let toStart = toCount == 0 ? max(0, slice.first!.toNumber - 1) : slice.first!.toNumber
            var out = ["@@ -\(fromStart),\(fromCount) +\(toStart),\(toCount) @@"]
            for line in slice {
                let mark: String
                switch line.kind {
                case .context: mark = " "
                case .removal: mark = "-"
                case .addition: mark = "+"
                }
                out.append(mark + line.text)
                if line.noNewline { out.append("\\ No newline at end of file") }
            }
            return out
        }
    }

    public enum ApplyError: Error, Equatable {
        /// A line of the patch does not match the text it applies to.
        case mismatch(line: Int)
    }

    /// The text a file has after `patch` (one file's part, as `patch(for:selection:reverse:)`
    /// makes it) is applied to `base` (`nil`: the file does not exist yet). Returns `nil` when
    /// the patch removes the file. Strict: every unchanged and removed line has to match.
    public static func applying(_ patch: String, to base: String?) throws -> String? {
        let patchLines = patch.components(separatedBy: "\n")
        if patchLines.contains("+++ /dev/null") { return nil }

        var source = (base ?? "").components(separatedBy: "\n")
        let sourceEndsWithNewline = base.map { $0.isEmpty || $0.hasSuffix("\n") } ?? true
        if sourceEndsWithNewline, source.last == "" { source.removeLast() }

        var result: [String] = []
        var position = 0 // next unread line of `source`, 0-based
        var endsWithNewline = sourceEndsWithNewline
        var lastKind: Character?
        // Lines before the first @@ are the file header (diff --git, ---, +++, mode lines).
        var inHunks = false

        for line in patchLines {
            if line.hasPrefix("@@") {
                inHunks = true
                let start = starts(of: line).0
                // `-0,0` (a new file) and `-n,0` (insert after line n) count from the line before.
                let fromCount = line.split(separator: " ").first { $0.hasPrefix("-") }
                    .flatMap { $0.split(separator: ",").dropFirst().first }.flatMap { Int($0) } ?? 1
                let target = fromCount == 0 ? start : start - 1
                guard target >= position, target <= source.count else { throw ApplyError.mismatch(line: target) }
                result += source[position..<target]
                position = target
                continue
            }
            guard inHunks, let mark = line.first else { continue }
            let text = String(line.dropFirst())
            switch mark {
            case " ":
                guard position < source.count, source[position] == text else { throw ApplyError.mismatch(line: position + 1) }
                result.append(text)
                position += 1
            case "-":
                guard position < source.count, source[position] == text else { throw ApplyError.mismatch(line: position + 1) }
                position += 1
            case "+":
                result.append(text)
            case "\\":
                // Belongs to the line before: an added last line without a newline, or the
                // removal of a last line that had none (so the new last line does again).
                if lastKind == "+" { endsWithNewline = false } else if lastKind == "-" { endsWithNewline = true }
            default:
                continue
            }
            if mark != "\\" { lastKind = mark }
        }
        result += source[position...]
        return result.joined(separator: "\n") + (endsWithNewline && !result.isEmpty ? "\n" : "")
    }

    /// The old and new start lines of a `@@ -a,b +c,d @@` header.
    static func starts(of header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func number(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 1 }
            return Int(part.dropFirst().split(separator: ",").first ?? "1") ?? 1
        }
        return (number("-"), number("+"))
    }
}
