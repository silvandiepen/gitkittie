// Taken from Lezin (`lezin/apps/editor-kit`, MarkdownFormatting.swift, at origin/main 97dc7d7) so Tasks edits
// Markdown with the same commands as Lezin. Keep it in step with Lezin; do not change it here.

import Foundation

/// A formatting command the editor can apply to a Markdown selection — from the
/// formatting toolbar, the floating selection bar, or a keyboard shortcut.
public enum MarkdownFormatAction: String, CaseIterable, Sendable {
    case bold
    case italic
    case strikethrough
    case code
    case heading1
    case heading2
    case heading3
    case bulletList
    case orderedList
    case quote
    case plainText

    public var systemImage: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .heading1: return "1.square"
        case .heading2: return "2.square"
        case .heading3: return "3.square"
        case .bulletList: return "list.bullet"
        case .orderedList: return "list.number"
        case .quote: return "text.quote"
        case .plainText: return "eraser"
        }
    }

    public var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .code: return "Code"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .bulletList: return "Bulleted List"
        case .orderedList: return "Numbered List"
        case .quote: return "Quote"
        case .plainText: return "Clear Formatting"
        }
    }

    /// The command name the preview bridge understands.
    public var previewCommand: String { rawValue }
}

/// Pure Markdown source transformations: given text and a selection, toggle inline
/// markers or block prefixes and return the new text plus the selection to restore.
public enum MarkdownFormatter {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let selection: NSRange

        public init(text: String, selection: NSRange) {
            self.text = text
            self.selection = selection
        }
    }

    public static func apply(_ action: MarkdownFormatAction, to text: String, selection: NSRange) -> Result {
        let clamped = clampedRange(selection, in: text)
        switch action {
        case .bold: return toggleInline(marker: "**", text: text, selection: clamped)
        case .italic: return toggleInline(marker: "*", text: text, selection: clamped)
        case .strikethrough: return toggleInline(marker: "~~", text: text, selection: clamped)
        case .code: return toggleInline(marker: "`", text: text, selection: clamped)
        case .heading1: return toggleHeading(level: 1, text: text, selection: clamped)
        case .heading2: return toggleHeading(level: 2, text: text, selection: clamped)
        case .heading3: return toggleHeading(level: 3, text: text, selection: clamped)
        case .bulletList: return toggleLinePrefix(text: text, selection: clamped, kind: .bullet)
        case .orderedList: return toggleLinePrefix(text: text, selection: clamped, kind: .ordered)
        case .quote: return toggleLinePrefix(text: text, selection: clamped, kind: .quote)
        case .plainText: return stripFormatting(text: text, selection: clamped)
        }
    }

    // MARK: - Active styles

    /// The formatting styles that apply at the given selection — used to render
    /// toolbar buttons in their active state. Clicking an active style removes it.
    public static func activeStyles(in text: String, selection: NSRange) -> Set<MarkdownFormatAction> {
        let clamped = clampedRange(selection, in: text)
        let nsText = text as NSString
        var result: Set<MarkdownFormatAction> = []

        let inlinePairs: [(MarkdownFormatAction, String)] = [
            (.bold, "**"), (.italic, "*"), (.strikethrough, "~~"), (.code, "`"),
        ]
        for (action, marker) in inlinePairs {
            if enclosingInlineSpan(marker: marker, text: nsText, selection: clamped) != nil {
                result.insert(action)
                continue
            }
            guard clamped.length > 0 else { continue }
            let selected = nsText.substring(with: clamped)
            let markerLength = (marker as NSString).length
            if selected.hasPrefix(marker), selected.hasSuffix(marker),
               (selected as NSString).length >= markerLength * 2,
               !(marker == "*" && selected.hasPrefix("**") && selected.hasSuffix("**")) {
                result.insert(action)
            }
        }

        let lineRange = nsText.lineRange(for: NSRange(location: clamped.location, length: 0))
        let line = nsText.substring(with: lineRange)
        switch currentHeadingLevel(of: line) {
        case 1: result.insert(.heading1)
        case 2: result.insert(.heading2)
        case 3: result.insert(.heading3)
        default: break
        }
        if hasPrefix(.bullet, line: line) { result.insert(.bulletList) }
        if hasPrefix(.ordered, line: line) { result.insert(.orderedList) }
        if hasPrefix(.quote, line: line) { result.insert(.quote) }
        return result
    }

    /// The marker pair enclosing the selection on its line, if any — e.g. the
    /// `**`…`**` around a word selected inside a longer bold span.
    private static func enclosingInlineSpan(
        marker: String, text: NSString, selection: NSRange
    ) -> (open: NSRange, close: NSRange)? {
        guard selection.location <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        guard NSMaxRange(selection) <= NSMaxRange(lineRange) else { return nil }
        let markerLength = (marker as NSString).length
        let positions = markerPositions(marker, in: text, range: lineRange)
        var index = 0
        while index + 1 < positions.count {
            let open = positions[index]
            let close = positions[index + 1]
            if selection.location >= open + markerLength, NSMaxRange(selection) <= close {
                return (
                    NSRange(location: open, length: markerLength),
                    NSRange(location: close, length: markerLength)
                )
            }
            index += 2
        }
        return nil
    }

    /// Occurrences of a marker within a range. Single-character markers whose
    /// doubled form is a different marker ("*" vs "**", "~" vs "~~") skip
    /// positions that belong to the doubled form.
    private static func markerPositions(_ marker: String, in text: NSString, range: NSRange) -> [Int] {
        let markerLength = (marker as NSString).length
        let doubledChar: unichar? = (marker == "*" || marker == "~")
            ? (marker as NSString).character(at: 0)
            : nil
        var positions: [Int] = []
        var index = range.location
        let end = NSMaxRange(range)
        while index + markerLength <= end {
            guard text.substring(with: NSRange(location: index, length: markerLength)) == marker else {
                index += 1
                continue
            }
            if let doubled = doubledChar {
                let previousIsSame = index > range.location && text.character(at: index - 1) == doubled
                let nextIsSame = index + 1 < end && text.character(at: index + 1) == doubled
                if previousIsSame || nextIsSame {
                    index += 1
                    continue
                }
            }
            positions.append(index)
            index += markerLength
        }
        return positions
    }

    // MARK: - Inline markers

    private static func toggleInline(marker: String, text: String, selection: NSRange) -> Result {
        let nsText = text as NSString
        let markerLength = (marker as NSString).length

        // Inside a marked span (selection or caret): toggling removes the
        // enclosing markers.
        if let span = enclosingInlineSpan(marker: marker, text: nsText, selection: selection) {
            var updated = nsText.replacingCharacters(in: span.close, with: "")
            updated = (updated as NSString).replacingCharacters(in: span.open, with: "")
            return Result(
                text: updated,
                selection: NSRange(location: selection.location - markerLength, length: selection.length)
            )
        }

        // Collapsed selection: insert a marker pair and put the caret between them.
        guard selection.length > 0 else {
            let inserted = marker + marker
            let updated = nsText.replacingCharacters(in: selection, with: inserted)
            return Result(text: updated, selection: NSRange(location: selection.location + markerLength, length: 0))
        }

        let selected = nsText.substring(with: selection)

        // Selection includes the markers ("**bold**" selected).
        if selected.hasPrefix(marker), selected.hasSuffix(marker),
           (selected as NSString).length >= markerLength * 2,
           !(marker == "*" && selected.hasPrefix("**") && selected.hasSuffix("**")) {
            let inner = (selected as NSString).substring(
                with: NSRange(location: markerLength, length: (selected as NSString).length - markerLength * 2)
            )
            let updated = nsText.replacingCharacters(in: selection, with: inner)
            return Result(text: updated, selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }

        // Markers directly around the selection ("bold" selected inside "**bold**").
        let before = NSRange(location: selection.location - markerLength, length: markerLength)
        let after = NSRange(location: NSMaxRange(selection), length: markerLength)
        if before.location >= 0, NSMaxRange(after) <= nsText.length,
           nsText.substring(with: before) == marker, nsText.substring(with: after) == marker,
           !(marker == "*" && isDoubleStar(nsText, around: selection)) {
            var updated = nsText.replacingCharacters(in: after, with: "")
            updated = (updated as NSString).replacingCharacters(in: before, with: "")
            return Result(text: updated, selection: NSRange(location: before.location, length: selection.length))
        }

        // Wrap, keeping surrounding whitespace outside the markers.
        let core = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else {
            return Result(text: text, selection: selection)
        }
        let leading = String(selected.prefix { $0.isWhitespace })
        let trailing = String(selected.reversed().prefix { $0.isWhitespace }.reversed())
        let wrapped = leading + marker + core + marker + trailing
        let updated = nsText.replacingCharacters(in: selection, with: wrapped)
        return Result(
            text: updated,
            selection: NSRange(location: selection.location, length: (wrapped as NSString).length)
        )
    }

    /// True when a single-star toggle would collide with a bold (`**`) marker pair.
    private static func isDoubleStar(_ text: NSString, around selection: NSRange) -> Bool {
        let beforeTwo = NSRange(location: selection.location - 2, length: 2)
        let afterTwo = NSRange(location: NSMaxRange(selection), length: 2)
        guard beforeTwo.location >= 0, NSMaxRange(afterTwo) <= text.length else { return false }
        return text.substring(with: beforeTwo) == "**" && text.substring(with: afterTwo) == "**"
    }

    // MARK: - Headings

    private static func toggleHeading(level: Int, text: String, selection: NSRange) -> Result {
        transformLines(text: text, selection: selection) { line in
            let stripped = strippedBlockPrefix(line)
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) && currentHeadingLevel(of: line) == level {
                return stripped
            }
            return prefix + stripped
        }
    }

    private static func currentHeadingLevel(of line: String) -> Int {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, line.dropFirst(hashes.count).first == " " else { return 0 }
        return hashes.count
    }

    // MARK: - Line prefixes

    private enum LinePrefixKind {
        case bullet
        case ordered
        case quote
    }

    private static func toggleLinePrefix(text: String, selection: NSRange, kind: LinePrefixKind) -> Result {
        var orderedIndex = 0
        // Toggle off only when every selected line already carries the prefix.
        var allPrefixed = true
        enumerateSelectedLines(text: text, selection: selection) { line in
            if !hasPrefix(kind, line: line) { allPrefixed = false }
        }
        return transformLines(text: text, selection: selection) { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if allPrefixed {
                return removePrefix(kind, line: line)
            }
            orderedIndex += 1
            let stripped = strippedBlockPrefix(line)
            switch kind {
            case .bullet: return "- " + stripped
            case .ordered: return "\(orderedIndex). " + stripped
            case .quote: return "> " + stripped
            }
        }
    }

    private static func hasPrefix(_ kind: LinePrefixKind, line: String) -> Bool {
        switch kind {
        case .bullet:
            return line.range(of: #"^\s*[-*+]\s"#, options: .regularExpression) != nil
        case .ordered:
            return line.range(of: #"^\s*\d+\.\s"#, options: .regularExpression) != nil
        case .quote:
            return line.range(of: #"^\s*>\s"#, options: .regularExpression) != nil
        }
    }

    private static func removePrefix(_ kind: LinePrefixKind, line: String) -> String {
        let pattern: String
        switch kind {
        case .bullet: pattern = #"^\s*[-*+]\s+"#
        case .ordered: pattern = #"^\s*\d+\.\s+"#
        case .quote: pattern = #"^\s*>\s+"#
        }
        return line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// A line with any leading heading, list, or quote marker removed.
    private static func strippedBlockPrefix(_ line: String) -> String {
        line.replacingOccurrences(
            of: #"^\s*(#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s+)"#,
            with: "",
            options: .regularExpression
        )
    }

    // MARK: - Plain text

    private static func stripFormatting(text: String, selection: NSRange) -> Result {
        if selection.length > 0 {
            let nsText = text as NSString
            var selected = nsText.substring(with: selection)
            for marker in ["**", "~~", "`", "*"] {
                selected = selected.replacingOccurrences(of: marker, with: "")
            }
            let updated = nsText.replacingCharacters(in: selection, with: selected)
            return Result(text: updated, selection: NSRange(location: selection.location, length: (selected as NSString).length))
        }
        return transformLines(text: text, selection: selection) { strippedBlockPrefix($0) }
    }

    // MARK: - Line helpers

    private static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    private static func selectedLineRange(text: NSString, selection: NSRange) -> NSRange {
        text.lineRange(for: selection)
    }

    private static func enumerateSelectedLines(text: String, selection: NSRange, _ body: (String) -> Void) {
        let nsText = text as NSString
        let lineRange = selectedLineRange(text: nsText, selection: selection)
        nsText.substring(with: lineRange)
            .components(separatedBy: "\n")
            .forEach { if !$0.isEmpty || true { body($0) } }
    }

    private static func transformLines(text: String, selection: NSRange, _ transform: (String) -> String) -> Result {
        let nsText = text as NSString
        let lineRange = selectedLineRange(text: nsText, selection: selection)
        let block = nsText.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        let content = hadTrailingNewline ? String(block.dropLast()) : block
        let transformed = content
            .components(separatedBy: "\n")
            .map(transform)
            .joined(separator: "\n")
            + (hadTrailingNewline ? "\n" : "")
        let updated = nsText.replacingCharacters(in: lineRange, with: transformed)
        return Result(
            text: updated,
            selection: NSRange(location: lineRange.location, length: (transformed as NSString).length - (hadTrailingNewline ? 1 : 0))
        )
    }
}

// MARK: - Extra actions (plugin-driven)

/// Additional formatting/insert actions surfaced in the toolbar's overflow menu.
/// Some are always available; others only when the matching Nizel plugin is on.
public enum MarkdownExtraAction: String, CaseIterable, Sendable {
    case link
    case image
    case table
    case codeBlock
    case taskList
    case highlight
    case subscriptText
    case superscriptText
    case inlineMath
    case mathBlock
    case footnote
    case alertBlock
    case detailsBlock
    case tocBlock
    case mermaidBlock

    /// The Nizel plugin id this action depends on; nil = always available.
    public var requiredPlugin: String? {
        switch self {
        case .link, .image, .table, .codeBlock: return nil
        case .taskList: return "task-list"
        case .highlight, .subscriptText, .superscriptText: return "typography"
        case .inlineMath, .mathBlock: return "math"
        case .footnote: return "footnotes"
        case .alertBlock: return "alert"
        case .detailsBlock: return "details"
        case .tocBlock: return "toc"
        case .mermaidBlock: return "diagrams"
        }
    }

    public var title: String {
        switch self {
        case .link: return "Link"
        case .image: return "Image"
        case .table: return "Table"
        case .codeBlock: return "Code Block"
        case .taskList: return "Task List"
        case .highlight: return "Highlight"
        case .subscriptText: return "Subscript"
        case .superscriptText: return "Superscript"
        case .inlineMath: return "Inline Math"
        case .mathBlock: return "Math Block"
        case .footnote: return "Footnote"
        case .alertBlock: return "Alert"
        case .detailsBlock: return "Details"
        case .tocBlock: return "Table of Contents"
        case .mermaidBlock: return "Mermaid Diagram"
        }
    }

    public var systemImage: String {
        switch self {
        case .link: return "link"
        case .image: return "photo"
        case .table: return "tablecells"
        case .codeBlock: return "curlybraces"
        case .taskList: return "checklist"
        case .highlight: return "highlighter"
        case .subscriptText: return "textformat.subscript"
        case .superscriptText: return "textformat.superscript"
        case .inlineMath: return "x.squareroot"
        case .mathBlock: return "function"
        case .footnote: return "text.append"
        case .alertBlock: return "exclamationmark.triangle"
        case .detailsBlock: return "chevron.down.square"
        case .tocBlock: return "list.bullet.indent"
        case .mermaidBlock: return "flowchart"
        }
    }

    /// Actions available for a given set of enabled Nizel plugin ids.
    public static func available(forEnabledPlugins plugins: Set<String>) -> [MarkdownExtraAction] {
        allCases.filter { action in
            action.requiredPlugin.map(plugins.contains) ?? true
        }
    }
}

public extension MarkdownFormatter {
    static func apply(_ action: MarkdownExtraAction, to text: String, selection: NSRange) -> Result {
        let nsText = text as NSString
        let clamped = NSRange(
            location: min(max(0, selection.location), nsText.length),
            length: min(selection.length, nsText.length - min(max(0, selection.location), nsText.length))
        )
        let selected = nsText.substring(with: clamped)

        func wrap(_ open: String, _ close: String, placeholder: String = "") -> Result {
            let content = selected.isEmpty ? placeholder : selected
            let replacement = open + content + close
            let updated = nsText.replacingCharacters(in: clamped, with: replacement)
            let contentStart = clamped.location + (open as NSString).length
            return Result(text: updated, selection: NSRange(location: contentStart, length: (content as NSString).length))
        }

        func insertBlock(_ block: String, selectionOffset: Int? = nil, selectionLength: Int = 0) -> Result {
            let lineRange = nsText.lineRange(for: clamped)
            let needsLeadingNewline = lineRange.location > 0
            let replacement = (needsLeadingNewline && !nsText.substring(with: lineRange).isEmpty ? "" : "") + block
            let updated = nsText.replacingCharacters(in: NSRange(location: NSMaxRange(lineRange), length: 0), with: replacement)
            let base = NSMaxRange(lineRange)
            let cursor = selectionOffset.map { base + $0 } ?? base + (replacement as NSString).length
            return Result(text: updated, selection: NSRange(location: cursor, length: selectionLength))
        }

        switch action {
        case .link:
            let result = wrap("[", "](url)", placeholder: "title")
            // Leave "url" selected so the destination can be typed straight away.
            let urlStart = result.selection.location + result.selection.length + 2
            return Result(text: result.text, selection: NSRange(location: urlStart, length: 3))
        case .image:
            let result = wrap("![", "](url)", placeholder: "alt")
            let urlStart = result.selection.location + result.selection.length + 2
            return Result(text: result.text, selection: NSRange(location: urlStart, length: 3))
        case .codeBlock:
            return wrap("```\n", "\n```", placeholder: "code")
        case .inlineMath:
            return wrap("$", "$", placeholder: "x")
        case .highlight:
            return wrap("==", "==", placeholder: "text")
        case .subscriptText:
            return wrap("~", "~", placeholder: "sub")
        case .superscriptText:
            return wrap("^", "^", placeholder: "sup")
        case .mathBlock:
            return insertBlock("$$\n\(selected.isEmpty ? "x = y" : selected)\n$$\n", selectionOffset: 3, selectionLength: (selected.isEmpty ? "x = y" : selected).count)
        case .mermaidBlock:
            return insertBlock("```mermaid\ngraph TD\n  A --> B\n```\n")
        case .tocBlock:
            return insertBlock("[[toc]]\n")
        case .alertBlock:
            let content = selected.isEmpty ? "Something worth calling out." : selected
            let quoted = content.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            return insertBlock("> [!NOTE]\n\(quoted)\n")
        case .detailsBlock:
            let content = selected.isEmpty ? "Hidden content." : selected
            return insertBlock("<details>\n<summary>Summary</summary>\n\n\(content)\n\n</details>\n")
        case .table:
            return insertBlock("| Column | Column |\n| --- | --- |\n| Cell | Cell |\n| Cell | Cell |\n")
        case .taskList:
            let lineRange = nsText.lineRange(for: clamped)
            let block = nsText.substring(with: lineRange)
            let hadNewline = block.hasSuffix("\n")
            let content = hadNewline ? String(block.dropLast()) : block
            let lines = content.components(separatedBy: "\n").map { line -> String in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                if line.range(of: #"^\s*- \[[ xX]\]\s"#, options: .regularExpression) != nil {
                    return line.replacingOccurrences(of: #"^\s*- \[[ xX]\]\s+"#, with: "", options: .regularExpression)
                }
                let stripped = line.replacingOccurrences(
                    of: #"^\s*(#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s+)"#, with: "", options: .regularExpression
                )
                return "- [ ] " + stripped
            }
            let transformed = lines.joined(separator: "\n") + (hadNewline ? "\n" : "")
            let updated = nsText.replacingCharacters(in: lineRange, with: transformed)
            return Result(
                text: updated,
                selection: NSRange(location: lineRange.location, length: (transformed as NSString).length - (hadNewline ? 1 : 0))
            )
        case .footnote:
            let existing = (try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#))
                .map { regex in
                    regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
                        .compactMap { Int(nsText.substring(with: $0.range(at: 1))) }
                        .max() ?? 0
                } ?? 0
            let number = existing + 1
            let marker = "[^\(number)]"
            var updated = nsText.replacingCharacters(in: NSRange(location: NSMaxRange(clamped), length: 0), with: marker) as NSString
            let needsNewline = updated.length > 0 && updated.character(at: updated.length - 1) != 10
            updated = updated.replacingCharacters(
                in: NSRange(location: updated.length, length: 0),
                with: "\(needsNewline ? "\n" : "")\n[^\(number)]: "
            ) as NSString
            return Result(text: updated as String, selection: NSRange(location: updated.length, length: 0))
        }
    }
}
