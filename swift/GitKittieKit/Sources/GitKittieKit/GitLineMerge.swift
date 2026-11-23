import Foundation

/// A three-way merge of one file's text, line by line, that only calls it a conflict when
/// both sides changed the same lines (or both inserted at the same spot).
///
/// `git merge-file` also refuses changes that merely touch — one side edits line 2, the other
/// removes line 3 — which is the common case when picking or undoing a change from an older
/// commit next to code edited since. This merge takes those; it is used after `merge-file`
/// reports a conflict, never instead of it.
public enum GitLineMerge {
    /// `ours` with the change from `base` to `theirs` applied, or `nil` when the two changed
    /// the same lines.
    public static func merge(base: String, ours: String, theirs: String) -> String? {
        let baseLines = base.components(separatedBy: "\n")
        let oursLines = ours.components(separatedBy: "\n")
        let theirsLines = theirs.components(separatedBy: "\n")

        let oursEdit = Edit(from: baseLines, to: oursLines)
        var theirsEdit = Edit(from: baseLines, to: theirsLines)

        // A change both sides made the same way is not a conflict: it is already in `ours`.
        for (gap, lines) in theirsEdit.inserted where oursEdit.inserted[gap] == lines {
            // The removals that belong to this replacement: the run of removed lines just before it.
            var line = gap - 1
            var run: [Int] = []
            while line >= 0, theirsEdit.removed.contains(line), oursEdit.removed.contains(line) {
                run.append(line)
                line -= 1
            }
            theirsEdit.inserted[gap] = nil
            theirsEdit.removed.subtract(run)
        }
        for removed in theirsEdit.removed where oursEdit.removed.contains(removed)
            && theirsEdit.inserted[removed + 1] == nil && oursEdit.inserted[removed + 1] == nil {
            theirsEdit.removed.remove(removed) // both deleted the same line, and nothing else there
        }

        // Both sides removed or replaced the same line, or both inserted in the same gap.
        guard oursEdit.removed.isDisjoint(with: theirsEdit.removed) else { return nil }
        guard Set(oursEdit.inserted.keys).isDisjoint(with: Set(theirsEdit.inserted.keys)) else { return nil }
        // Where each base line and each gap between base lines sits in `ours`.
        var lineInOurs = [Int?](repeating: nil, count: baseLines.count)
        var gapInOurs = [Int](repeating: 0, count: baseLines.count + 1)
        var position = 0
        for index in 0...baseLines.count {
            gapInOurs[index] = position
            position += oursEdit.inserted[index]?.count ?? 0
            guard index < baseLines.count else { break }
            if !oursEdit.removed.contains(index) {
                lineInOurs[index] = position
                position += 1
            }
        }

        // Theirs' changes as edits on `ours`, applied from the bottom up so positions hold.
        var result = oursLines
        var operations: [(position: Int, remove: Bool, lines: [String])] = []
        for index in theirsEdit.removed {
            guard let at = lineInOurs[index] else { return nil }
            operations.append((at, true, []))
        }
        for (gap, lines) in theirsEdit.inserted {
            operations.append((gapInOurs[gap], false, lines))
        }
        // Bottom up; at the same position, remove the line before inserting in front of it.
        operations.sort { $0.position != $1.position ? $0.position > $1.position : $0.remove && !$1.remove }
        for operation in operations {
            if operation.remove {
                result.remove(at: operation.position)
            } else {
                result.insert(contentsOf: operation.lines, at: operation.position)
            }
        }
        return result.joined(separator: "\n")
    }

    /// One side's change against base: which base lines it removed, and which lines it
    /// inserted in front of which base line (`base.count`: at the end).
    private struct Edit {
        var removed = Set<Int>()
        var inserted: [Int: [String]] = [:]

        init(from base: [String], to other: [String]) {
            let difference = other.difference(from: base)
            var insertedAt = Set<Int>()
            for change in difference {
                switch change {
                case let .remove(offset, _, _): removed.insert(offset)
                case let .insert(offset, _, _): insertedAt.insert(offset)
                }
            }
            // Walk both sides to find, for each inserted line, the base line it stands before.
            var baseIndex = 0
            for otherIndex in other.indices {
                while baseIndex < base.count, removed.contains(baseIndex) { baseIndex += 1 }
                if insertedAt.contains(otherIndex) {
                    inserted[baseIndex, default: []].append(other[otherIndex])
                } else {
                    baseIndex += 1
                }
            }
        }
    }
}
