import Foundation

/// One line of a hunk as a diff view draws it: what kind it is, its text, and its number in
/// the old and the new file.
public struct GitDiffLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case context, removal, addition }

    public let hunkID: String
    /// Index into `GitHunk.lines` — what `GitChangeSelection` stores.
    public let index: Int
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public var id: String { "\(hunkID)#\(index)" }
    public var isChange: Bool { kind != .context }
}

/// A row of a side-by-side diff: the old file's line on the left, the new file's on the
/// right. A removal and the addition that replaced it share a row.
public struct GitDiffRow: Sendable, Equatable, Identifiable {
    public let left: GitDiffLine?
    public let right: GitDiffLine?
    public var id: String { (left?.id ?? "-") + "|" + (right?.id ?? "-") }
}

public enum GitDiffLayout {
    /// The hunk's lines with their numbers. `\ No newline` markers and the parser's trailing
    /// empty string are not lines of the file and are left out.
    public static func lines(of hunk: GitHunk) -> [GitDiffLine] {
        let (oldStart, newStart) = GitPatchBuilder.starts(of: hunk.header)
        var old = oldStart
        var new = newStart
        var result: [GitDiffLine] = []
        for (index, raw) in hunk.lines.enumerated() {
            guard let mark = raw.first, mark != "\\" else { continue }
            let text = String(raw.dropFirst())
            switch mark {
            case "+":
                result.append(GitDiffLine(hunkID: hunk.id, index: index, kind: .addition, text: text, oldNumber: nil, newNumber: new))
                new += 1
            case "-":
                result.append(GitDiffLine(hunkID: hunk.id, index: index, kind: .removal, text: text, oldNumber: old, newNumber: nil))
                old += 1
            default:
                result.append(GitDiffLine(hunkID: hunk.id, index: index, kind: .context, text: text, oldNumber: old, newNumber: new))
                old += 1
                new += 1
            }
        }
        return result
    }

    /// The hunk as side-by-side rows: unchanged lines on both sides, and each run of removals
    /// paired line for line with the run of additions that follows it.
    public static func rows(of hunk: GitHunk) -> [GitDiffRow] {
        var rows: [GitDiffRow] = []
        var removals: [GitDiffLine] = []
        var additions: [GitDiffLine] = []

        func flush() {
            for offset in 0..<max(removals.count, additions.count) {
                rows.append(GitDiffRow(
                    left: removals.indices.contains(offset) ? removals[offset] : nil,
                    right: additions.indices.contains(offset) ? additions[offset] : nil))
            }
            removals = []
            additions = []
        }

        for line in lines(of: hunk) {
            switch line.kind {
            case .context:
                flush()
                rows.append(GitDiffRow(left: line, right: line))
            case .removal:
                // A removal after additions starts a new pairing.
                if !additions.isEmpty { flush() }
                removals.append(line)
            case .addition:
                additions.append(line)
            }
        }
        flush()
        return rows
    }
}

extension GitChangeSelection {
    /// The same chosen lines in a different reading of the same commit (more or less
    /// context, for example), matched by file, kind and line number. Lines that no longer
    /// appear are dropped.
    public func remapped(from oldDiffs: [GitFileDiff], to newDiffs: [GitFileDiff]) -> GitChangeSelection {
        func key(_ path: String, _ line: GitDiffLine) -> String {
            "\(path)|\(line.kind)|\(line.oldNumber ?? -1)|\(line.newNumber ?? -1)"
        }
        var chosenKeys = Set<String>()
        for file in oldDiffs {
            for hunk in file.hunks {
                let chosen = lines[hunk.id] ?? []
                for line in GitDiffLayout.lines(of: hunk) where line.isChange && chosen.contains(line.index) {
                    chosenKeys.insert(key(file.path, line))
                }
            }
        }
        var result = GitChangeSelection()
        for file in newDiffs {
            for hunk in file.hunks {
                let indexes = GitDiffLayout.lines(of: hunk)
                    .filter { $0.isChange && chosenKeys.contains(key(file.path, $0)) }
                    .map(\.index)
                if !indexes.isEmpty { result.lines[hunk.id] = Set(indexes) }
            }
        }
        return result
    }
}

extension GitFileDiff {
    /// One file's diff from hunks text — what a hosted provider returns per file, starting at
    /// the first `@@`. Hunk ids follow the same `path:index` scheme as a diff read from git,
    /// so the patch builder and choosing lines work the same way on both.
    public init(path: String, oldPath: String? = nil, hunksText: String, isNewFile: Bool = false, isDeletedFile: Bool = false) {
        var hunks: [GitHunk] = []
        var header: String?
        var lines: [String] = []
        func flush() {
            guard let current = header else { return }
            while lines.last == "" { lines.removeLast() }
            hunks.append(GitHunk(id: "\(path):\(hunks.count)", header: current, lines: lines))
            lines = []
        }
        for line in hunksText.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                flush()
                header = line
            } else if header != nil {
                lines.append(line)
            }
        }
        flush()
        self.init(path: path, oldPath: oldPath, hunks: hunks, isNewFile: isNewFile, isDeletedFile: isDeletedFile)
    }
}

extension GitDiffLayout {
    /// The whole file as one hunk: every line of `newText`, with the diff's removals and
    /// additions in place. For reading a change in full when the provider only sent the hunks.
    /// Returns nil when the hunks do not line up with `newText` (it changed since).
    public static func fullFile(newText: String, hunks: [GitHunk], path: String) -> GitHunk? {
        var newLines = newText.components(separatedBy: "\n")
        if newText.hasSuffix("\n") { newLines.removeLast() }

        var out: [String] = []
        var next = 1 // next line of the new file, 1-based
        var oldCount = 0
        for hunk in hunks.sorted(by: { GitPatchBuilder.starts(of: $0.header).1 < GitPatchBuilder.starts(of: $1.header).1 }) {
            let start = max(1, GitPatchBuilder.starts(of: hunk.header).1)
            // Unchanged lines up to the hunk (a pure removal hunk reports the line before it).
            let hunkAdds = hunk.lines.contains { $0.hasPrefix("+") || $0.hasPrefix(" ") }
            let upTo = hunkAdds ? start : start + 1
            guard upTo - 1 <= newLines.count, next <= upTo else { return nil }
            while next < upTo {
                out.append(" " + newLines[next - 1])
                next += 1
                oldCount += 1
            }
            for line in hunk.lines where !line.isEmpty {
                switch line.first {
                case "+":
                    guard next <= newLines.count, newLines[next - 1] == String(line.dropFirst()) else { return nil }
                    out.append(line)
                    next += 1
                case " ":
                    guard next <= newLines.count, newLines[next - 1] == String(line.dropFirst()) else { return nil }
                    out.append(line)
                    next += 1
                    oldCount += 1
                case "-":
                    out.append(line)
                    oldCount += 1
                default:
                    out.append(line) // "\ No newline at end of file"
                }
            }
        }
        while next <= newLines.count {
            out.append(" " + newLines[next - 1])
            next += 1
            oldCount += 1
        }
        return GitHunk(id: "\(path):0", header: "@@ -1,\(oldCount) +1,\(newLines.count) @@", lines: out)
    }
}
