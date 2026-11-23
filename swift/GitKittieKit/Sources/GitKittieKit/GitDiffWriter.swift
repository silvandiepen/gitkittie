import Foundation

/// Writes the hunks of a unified diff between two texts, the way `git diff` prints them
/// after the file header: `@@ -a,b +c,d @@` lines with three lines of context.
public enum GitDiffWriter {
    /// `nil` text: the file does not exist on that side. Empty result: no difference.
    public static func hunks(from old: String?, to new: String?, context: Int = 3) -> String {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        guard oldLines != newLines else { return "" }

        // Walk both texts with the standard library's diff, giving each line its kind.
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        struct Line { var mark: Character; var text: String; var old: Int; var new: Int }
        var script: [Line] = []
        var o = 0
        var n = 0
        while o < oldLines.count || n < newLines.count {
            if o < oldLines.count, removed.contains(o) {
                script.append(Line(mark: "-", text: oldLines[o], old: o, new: n))
                o += 1
            } else if n < newLines.count, inserted.contains(n) {
                script.append(Line(mark: "+", text: newLines[n], old: o, new: n))
                n += 1
            } else {
                script.append(Line(mark: " ", text: newLines[n], old: o, new: n))
                o += 1
                n += 1
            }
        }

        // Group the changes into hunks with `context` unchanged lines either side.
        let changes = script.indices.filter { script[$0].mark != " " }
        guard let first = changes.first else { return "" }
        var groups: [(Int, Int)] = []
        var start = first
        var end = first
        for index in changes.dropFirst() {
            if index - end > context * 2 { groups.append((start, end)); start = index }
            end = index
        }
        groups.append((start, end))

        var out: [String] = []
        for (lower, upper) in groups {
            let from = max(0, lower - context)
            let to = min(script.count - 1, upper + context)
            let slice = script[from...to]
            let oldCount = slice.filter { $0.mark != "+" }.count
            let newCount = slice.filter { $0.mark != "-" }.count
            let oldStart = oldCount == 0 ? slice.first!.old : slice.first!.old + 1
            let newStart = newCount == 0 ? slice.first!.new : slice.first!.new + 1
            out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            out += slice.map { String($0.mark) + $0.text }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func lines(of text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
