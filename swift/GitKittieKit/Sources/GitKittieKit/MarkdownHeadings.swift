// Taken from Lezin (`lezin/apps/editor-kit`, MarkdownHeadings.swift, at origin/main 97dc7d7) so Tasks edits
// Markdown with the same commands as Lezin. Keep it in step with Lezin; do not change it here.

import Foundation

/// A heading found in a Markdown document.
public struct MarkdownHeading: Equatable, Identifiable, Sendable {
    /// Position in the document order, which is stable enough to identify a
    /// heading for scrolling and stays valid as the text is edited around it.
    public let id: Int
    /// 1 for `#`, through 6 for `######`.
    public let level: Int
    /// The heading text, without its hashes or trailing hashes.
    public let title: String
    /// Character range of the whole heading line, for scrolling to it.
    public let range: NSRange
    /// 0-based line number.
    public let line: Int

    public init(id: Int, level: Int, title: String, range: NSRange, line: Int) {
        self.id = id
        self.level = level
        self.title = title
        self.range = range
        self.line = line
    }
}

/// Finds the headings in a Markdown document.
///
/// Separate from the styler because the table of contents needs the *structure*
/// — text, level, position — while the styler only needs to know which
/// characters to paint.
public enum MarkdownHeadingParser {
    /// Beyond this the document is not worth walking on every keystroke; the
    /// same guard the styler uses, for the same reason.
    public static let maximumParsedLength = 250_000

    public static func headings(in markdown: String) -> [MarkdownHeading] {
        let text = markdown as NSString
        guard text.length <= maximumParsedLength else { return [] }

        var headings: [MarkdownHeading] = []
        var insideFence = false
        var lineNumber = 0
        var location = 0

        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let raw = text.substring(with: lineRange)
            let line = raw.trimmingCharacters(in: .newlines)

            // A fence toggles in or out of code. Headings inside code blocks are
            // code, not structure — `# comment` in a shell snippet is not a
            // section of the document.
            if line.range(of: #"^\s{0,3}(```|~~~)"#, options: .regularExpression) != nil {
                insideFence.toggle()
            } else if !insideFence,
                      let heading = parse(line, id: headings.count, range: lineRange, line: lineNumber) {
                headings.append(heading)
            }

            lineNumber += 1
            location = NSMaxRange(lineRange)
            // A final line with no newline terminator would otherwise loop.
            if lineRange.length == 0 { break }
        }

        return headings
    }

    private static func parse(_ line: String, id: Int, range: NSRange, line lineNumber: Int) -> MarkdownHeading? {
        // Up to three leading spaces is still a heading; four makes it an
        // indented code block.
        guard let match = line.range(of: #"^\s{0,3}#{1,6}(\s|$)"#, options: .regularExpression) else {
            return nil
        }

        let marker = line[match].trimmingCharacters(in: .whitespaces)
        let level = marker.count { $0 == "#" }

        var title = String(line[match.upperBound...])
        // Closing hashes are decoration: `## Title ##` is titled "Title".
        title = title.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespaces)

        // `#` alone is a valid heading with no text; showing it as an empty rung
        // would be a mystery, so it is skipped.
        guard !title.isEmpty else { return nil }

        return MarkdownHeading(id: id, level: level, title: title, range: range, line: lineNumber)
    }
}
