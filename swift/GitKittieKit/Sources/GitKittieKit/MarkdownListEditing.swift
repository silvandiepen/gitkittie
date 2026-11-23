// Taken from Lezin (`lezin/apps/editor-kit`, MarkdownListEditing.swift, at origin/main 97dc7d7) so Tasks edits
// Markdown with the same commands as Lezin. Keep it in step with Lezin; do not change it here.

import Foundation

/// One list item parsed out of a single source line.
///
/// A line is `indent` + marker + `markerSpacing` + an optional `[ ]` checkbox +
/// `taskSpacing` + `content`, so an item can be re-rendered without losing the
/// author's own spacing.
public struct MarkdownListItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bullet(Character)
        case ordered(number: Int, delimiter: Character)
    }

    public var indent: String
    public var kind: Kind
    /// `nil` when the item carries no checkbox; otherwise whether it is ticked.
    public var checked: Bool?
    public var markerSpacing: String
    public var taskSpacing: String
    public var content: String

    public var markerText: String {
        switch kind {
        case .bullet(let character): return String(character)
        case .ordered(let number, let delimiter): return "\(number)\(delimiter)"
        }
    }

    public var checkboxText: String {
        guard let checked else { return "" }
        return "[\(checked ? "x" : " ")]" + taskSpacing
    }

    /// Everything before the content — what a continuation line has to repeat.
    public var prefix: String {
        indent + markerText + markerSpacing + checkboxText
    }

    /// The column the content starts at, which is where a child item indents to.
    public var contentColumn: Int { prefix.count }

    public var line: String { prefix + content }

    public var isEmpty: Bool { content.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// A replacement to apply to the editor's text storage.
public struct MarkdownListEdit: Equatable, Sendable {
    /// The range in the original text to replace.
    public let range: NSRange
    public let replacement: String
    /// The selection to restore afterwards, in the resulting text.
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

/// What the editor should do with a key it handed to this engine.
public enum MarkdownListOutcome: Equatable, Sendable {
    /// Not a list situation — let the text view do its own thing.
    case unhandled
    /// Swallow the key; the text is already right as it stands.
    case consumed
    case handled(MarkdownListEdit)
}

/// Tab, Shift-Tab and Return inside Markdown lists, as pure text transforms.
///
/// Tab starts a bulleted list on an ordinary line and indents an item that is
/// already in one; Shift-Tab starts a numbered list and outdents; Return
/// carries the list on to the next item and lets go of it on an empty one.
/// Inside a fenced code block none of that applies and the keys keep their
/// normal meaning.
public enum MarkdownListEditing {
    /// Used only where there is no parent item to align to.
    public static let indentUnit = "  "

    // MARK: - Parsing

    public static func parseItem(_ line: String) -> MarkdownListItem? {
        var rest = Substring(stripTerminator(line))

        let indent = rest.prefix { $0 == " " || $0 == "\t" }
        rest = rest.dropFirst(indent.count)

        guard let first = rest.first else { return nil }

        let kind: MarkdownListItem.Kind
        if first == "-" || first == "*" || first == "+" {
            kind = .bullet(first)
            rest = rest.dropFirst()
        } else if first.isNumber {
            let digits = rest.prefix { $0.isNumber }
            // Nine digits is already far past any list anyone writes; beyond
            // that it is a number at the start of a sentence, not a marker.
            guard digits.count <= 9, let number = Int(digits) else { return nil }
            var afterDigits = rest.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
            afterDigits = afterDigits.dropFirst()
            kind = .ordered(number: number, delimiter: delimiter)
            rest = afterDigits
        } else {
            return nil
        }

        let spacing = rest.prefix { $0 == " " || $0 == "\t" }
        // "-word" is a hyphenated word, not a list; "-" on its own is an item
        // someone is still typing.
        guard !spacing.isEmpty || rest.isEmpty else { return nil }
        rest = rest.dropFirst(spacing.count)
        let markerSpacing = spacing.isEmpty ? " " : String(spacing)

        var checked: Bool?
        var taskSpacing = ""
        if rest.count >= 3, rest.first == "[", rest.dropFirst(2).first == "]" {
            let box = rest[rest.index(rest.startIndex, offsetBy: 1)]
            if box == " " || box == "x" || box == "X" {
                let afterBox = rest.dropFirst(3)
                let boxSpacing = afterBox.prefix { $0 == " " || $0 == "\t" }
                if !boxSpacing.isEmpty || afterBox.isEmpty {
                    checked = box != " "
                    taskSpacing = boxSpacing.isEmpty ? " " : String(boxSpacing)
                    rest = afterBox.dropFirst(boxSpacing.count)
                }
            }
        }

        return MarkdownListItem(
            indent: String(indent),
            kind: kind,
            checked: checked,
            markerSpacing: markerSpacing,
            taskSpacing: taskSpacing,
            content: String(rest)
        )
    }

    // MARK: - Keys

    /// Tab: indent the item, or turn an ordinary line into a bulleted list.
    public static func tab(in text: String, selection: NSRange) -> MarkdownListOutcome {
        transformSelectedLines(in: text, selection: selection) { lines, index in
            let body = stripTerminator(lines[index])
            guard let item = parseItem(body) else {
                return startList(on: body, ordered: false, lines: lines, index: index)
            }
            guard let indent = nestedIndent(for: item, lines: lines, index: index) else {
                // The first item of a list has nothing to nest under. Refusing
                // is right, but a literal tab in its place would be worse.
                return .keep
            }
            return .replace(reindented(item, to: indent, lines: lines, index: index))
        }
    }

    /// Shift-Tab: outdent the item, leave the list at the outermost level, or
    /// turn an ordinary line into a numbered list.
    public static func backtab(in text: String, selection: NSRange) -> MarkdownListOutcome {
        transformSelectedLines(in: text, selection: selection) { lines, index in
            let body = stripTerminator(lines[index])
            guard let item = parseItem(body) else {
                return startList(on: body, ordered: true, lines: lines, index: index)
            }
            guard !item.indent.isEmpty else {
                return .replace(item.content)
            }
            let indent = parentIndent(for: item, lines: lines, index: index)
            return .replace(reindented(item, to: indent, lines: lines, index: index))
        }
    }

    /// Return: open the next item of the list, or step out of an empty one.
    public static func newline(in text: String, selection: NSRange) -> MarkdownListOutcome {
        guard selection.length == 0 else { return .unhandled }

        let nsText = text as NSString
        let caret = min(max(0, selection.location), nsText.length)
        let lines = documentLines(nsText)
        guard let index = lineIndex(containing: caret, lines: lines, in: nsText) else { return .unhandled }

        let lineRange = lines[index]
        guard !isInsideFencedCode(lines: lines, index: index, in: nsText) else { return .unhandled }

        let line = nsText.substring(with: lineRange)
        let body = stripTerminator(line)
        guard let item = parseItem(body) else { return .unhandled }

        let terminator = String(line.dropFirst(body.count))
        let bodyRange = NSRange(location: lineRange.location, length: (body as NSString).length)
        let prefixLength = (item.prefix as NSString).length

        // Inside the marker itself, Return is just a Return.
        guard caret - lineRange.location >= prefixLength else { return .unhandled }

        guard !item.isEmpty else {
            // An empty item ends the list — or first steps back out one level.
            if item.indent.isEmpty {
                return .handled(MarkdownListEdit(
                    range: bodyRange,
                    replacement: "",
                    selection: NSRange(location: bodyRange.location, length: 0)
                ))
            }
            var outdented = item
            outdented.indent = parentIndent(for: item, lines: linesText(lines, in: nsText), index: index)
            let replacement = outdented.line
            return .handled(MarkdownListEdit(
                range: bodyRange,
                replacement: replacement,
                selection: NSRange(location: bodyRange.location + (replacement as NSString).length, length: 0)
            ))
        }

        var next = item
        if case .ordered(let number, let delimiter) = item.kind {
            next.kind = .ordered(number: number + 1, delimiter: delimiter)
        }
        // A carried-over task item starts unticked; inheriting the tick would
        // mark work done that nobody has done.
        if next.checked != nil { next.checked = false }

        let inserted = (terminator.isEmpty ? "\n" : terminator) + next.prefix
        return .handled(MarkdownListEdit(
            range: NSRange(location: caret, length: 0),
            replacement: inserted,
            selection: NSRange(location: caret + (inserted as NSString).length, length: 0)
        ))
    }

    // MARK: - Line transforms

    private enum LineResult {
        case keep
        case replace(String)
    }

    private static func transformSelectedLines(
        in text: String,
        selection: NSRange,
        _ transform: ([String], Int) -> LineResult
    ) -> MarkdownListOutcome {
        let nsText = text as NSString
        let ranges = documentLines(nsText)
        let clamped = clamp(selection, in: nsText)
        guard let first = lineIndex(containing: clamped.location, lines: ranges, in: nsText) else { return .unhandled }
        // A selection ending exactly on a line start does not reach into that line.
        let lastLocation = clamped.length == 0
            ? clamped.location
            : max(clamped.location, NSMaxRange(clamped) - 1)
        guard let last = lineIndex(containing: lastLocation, lines: ranges, in: nsText) else { return .unhandled }
        guard !isInsideFencedCode(lines: ranges, index: first, in: nsText) else { return .unhandled }

        var lines = linesText(ranges, in: nsText)
        let caretLineBefore = lines[first]
        var changed = false

        for index in first...last {
            let original = lines[index]
            let terminator = String(original.dropFirst(stripTerminator(original).count))
            guard case .replace(let body) = transform(lines, index) else { continue }
            let updated = body + terminator
            guard updated != original else { continue }
            lines[index] = updated
            changed = true
        }

        guard changed else {
            // Still a list situation: swallow the key rather than let a literal
            // tab land in the middle of an item.
            return parseItem(caretLineBefore) == nil ? .unhandled : .consumed
        }

        let blockStart = ranges[first].location
        let blockEnd = NSMaxRange(ranges[last])
        let replacement = lines[first...last].joined()
        let range = NSRange(location: blockStart, length: blockEnd - blockStart)

        guard clamped.length == 0 else {
            let trailing = replacement.hasSuffix("\n") ? 1 : 0
            return .handled(MarkdownListEdit(
                range: range,
                replacement: replacement,
                selection: NSRange(location: blockStart, length: (replacement as NSString).length - trailing)
            ))
        }

        // Keep the caret where it was relative to the item's content.
        let offsetInLine = clamped.location - blockStart
        let oldPrefix = prefixLength(of: caretLineBefore)
        let newPrefix = prefixLength(of: lines[first])
        let caretOffset = offsetInLine < oldPrefix ? newPrefix : offsetInLine + newPrefix - oldPrefix
        return .handled(MarkdownListEdit(
            range: range,
            replacement: replacement,
            selection: NSRange(location: blockStart + max(0, caretOffset), length: 0)
        ))
    }

    private static func startList(on body: String, ordered: Bool, lines: [String], index: Int) -> LineResult {
        let indent = String(body.prefix { $0 == " " || $0 == "\t" })
        let content = String(body.dropFirst(indent.count))
        if ordered {
            let number = nextOrderedNumber(indent: indent, lines: lines, index: index)
            return .replace(indent + "\(number). " + content)
        }
        return .replace(indent + "- " + content)
    }

    private static func reindented(
        _ item: MarkdownListItem, to indent: String, lines: [String], index: Int
    ) -> String {
        var moved = item
        moved.indent = indent
        if case .ordered(_, let delimiter) = item.kind {
            let number = nextOrderedNumber(indent: indent, lines: lines, index: index)
            moved.kind = .ordered(number: number, delimiter: delimiter)
        }
        return moved.line
    }

    // MARK: - Neighbouring items

    /// The indent an item moves to when it is nested under the item above it,
    /// or `nil` when it has no sibling above to become its parent.
    private static func nestedIndent(for item: MarkdownListItem, lines: [String], index: Int) -> String? {
        let width = item.indent.count
        var cursor = index - 1
        while cursor >= 0 {
            let body = stripTerminator(lines[cursor])
            guard let sibling = parseItem(body) else {
                // A blank line still sits inside a loose list.
                if body.trimmingCharacters(in: .whitespaces).isEmpty { cursor -= 1; continue }
                return nil
            }
            if sibling.indent.count == width {
                return String(repeating: " ", count: sibling.contentColumn)
            }
            if sibling.indent.count < width { return nil }
            cursor -= 1
        }
        return nil
    }

    /// The indent of the item this one is nested under, or no indent at all.
    private static func parentIndent(for item: MarkdownListItem, lines: [String], index: Int) -> String {
        let width = item.indent.count
        var cursor = index - 1
        while cursor >= 0 {
            let body = stripTerminator(lines[cursor])
            if let candidate = parseItem(body), candidate.indent.count < width {
                return candidate.indent
            }
            cursor -= 1
        }
        let trimmed = max(0, width - indentUnit.count)
        return String(repeating: " ", count: trimmed)
    }

    /// The number the next item at this indent should carry.
    private static func nextOrderedNumber(indent: String, lines: [String], index: Int) -> Int {
        let width = indent.count
        var cursor = index - 1
        while cursor >= 0 {
            let body = stripTerminator(lines[cursor])
            guard let sibling = parseItem(body) else {
                if body.trimmingCharacters(in: .whitespaces).isEmpty { cursor -= 1; continue }
                return 1
            }
            if sibling.indent.count < width { return 1 }
            if sibling.indent.count == width {
                if case .ordered(let number, _) = sibling.kind { return number + 1 }
                return 1
            }
            cursor -= 1
        }
        return 1
    }

    // MARK: - Fenced code

    private static func isInsideFencedCode(lines: [NSRange], index: Int, in text: NSString) -> Bool {
        var open = false
        for cursor in 0..<index {
            let body = stripTerminator(text.substring(with: lines[cursor]))
            if isFenceLine(body) { open.toggle() }
        }
        return open
    }

    private static func isFenceLine(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    // MARK: - Text helpers

    private static func stripTerminator(_ line: String) -> String {
        if line.hasSuffix("\r\n") { return String(line.dropLast(2)) }
        if line.hasSuffix("\n") || line.hasSuffix("\r") { return String(line.dropLast()) }
        return line
    }

    private static func prefixLength(of line: String) -> Int {
        guard let item = parseItem(line) else {
            return (String(line.prefix { $0 == " " || $0 == "\t" }) as NSString).length
        }
        return (item.prefix as NSString).length
    }

    private static func clamp(_ range: NSRange, in text: NSString) -> NSRange {
        let location = min(max(0, range.location), text.length)
        return NSRange(location: location, length: min(max(0, range.length), text.length - location))
    }

    private static func documentLines(_ text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = 0
        while index < text.length {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            ranges.append(range)
            index = NSMaxRange(range)
        }
        // A trailing newline leaves an empty last line the caret can sit on.
        if let last = ranges.last {
            if NSMaxRange(last) == text.length, endsWithNewline(text) {
                ranges.append(NSRange(location: text.length, length: 0))
            }
        } else {
            ranges.append(NSRange(location: 0, length: 0))
        }
        return ranges
    }

    private static func endsWithNewline(_ text: NSString) -> Bool {
        guard text.length > 0 else { return false }
        let last = text.character(at: text.length - 1)
        return last == 10 || last == 13
    }

    private static func linesText(_ ranges: [NSRange], in text: NSString) -> [String] {
        ranges.map { text.substring(with: $0) }
    }

    private static func lineIndex(containing location: Int, lines: [NSRange], in text: NSString) -> Int? {
        guard !lines.isEmpty else { return nil }
        for (index, range) in lines.enumerated() {
            if location >= range.location, location < NSMaxRange(range) { return index }
        }
        return lines.indices.last
    }
}
