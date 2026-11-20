#if canImport(AppKit)
import AppKit

public typealias XFont = NSFont
public typealias XColor = NSColor
#elseif canImport(UIKit)
import UIKit

public typealias XFont = UIFont
public typealias XColor = UIColor
#endif

// Taken from Lezin (`lezin/apps/editor-kit`, MarkdownSourceStyling.swift) so Tasks edits
// Markdown the way Lezin does. Differences: fonts follow the base font's family instead of
// forcing monospaced, the template-variable colouring is left out, and the regexes are
// compiled once up front. LezinEditorKit lives inside Lezin's monorepo and cannot be a
// package dependency from here; fold the two together if it is ever published on its own.

/// In-editor Markdown styling: the source text keeps its exact characters, but
/// bold reads bold, italic slants, headings grow, code spans tint, and the
/// syntax markers themselves fade — a light preview inside the code view.
///
/// One implementation for every platform. The macOS and iOS apps each carried
/// their own copy of this file; they were identical apart from the imports, so
/// they drifted only by luck. `XFont`/`XColor` are the whole difference.
public enum MarkdownSourceStyler {
    public struct Palette {
        public let baseFont: XFont
        public let textColor: XColor
        public let accentColor: XColor
        public init(baseFont: XFont, textColor: XColor, accentColor: XColor) {
            self.baseFont = baseFont
            self.textColor = textColor
            self.accentColor = accentColor
        }

        public var markerColor: XColor { textColor.withAlphaComponent(0.38) }
        public var quoteColor: XColor { textColor.withAlphaComponent(0.72) }
        public var codeBackground: XColor { textColor.withAlphaComponent(0.07) }
    }

    /// Documents beyond this size skip styling entirely (typing latency).
    public static let maximumStyledLength = 250_000

    public static func apply(to storage: NSTextStorage, palette: Palette) {
        let text = storage.string as NSString
        guard text.length <= maximumStyledLength else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        let fullRange = NSRange(location: 0, length: text.length)
        storage.removeAttribute(.backgroundColor, range: fullRange)
        storage.removeAttribute(.obliqueness, range: fullRange)
        storage.addAttribute(.font, value: palette.baseFont, range: fullRange)
        storage.addAttribute(.foregroundColor, value: palette.textColor, range: fullRange)

        var insideFence = false
        var lineStart = 0
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            styleLine(lineRange, in: storage, text: text, palette: palette, insideFence: &insideFence)
            lineStart = NSMaxRange(lineRange)
        }
    }

    // MARK: - Lines

    private static func styleLine(
        _ lineRange: NSRange, in storage: NSTextStorage, text: NSString,
        palette: Palette, insideFence: inout Bool
    ) {
        let line = text.substring(with: lineRange)

        if line.range(of: #"^\s*(```|~~~)"#, options: .regularExpression) != nil {
            insideFence.toggle()
            storage.addAttribute(.foregroundColor, value: palette.markerColor, range: lineRange)
            return
        }

        if insideFence {
            storage.addAttribute(.backgroundColor, value: palette.codeBackground, range: trimmedRange(of: lineRange, line: line))
            return
        }

        // Headings: grow with level, dim the leading hashes.
        if let match = firstMatch(#"^(#{1,6})[ \t]"#, in: line) {
            let level = match.range(at: 1).length
            let font = headingFont(level: level, base: palette.baseFont)
            storage.addAttribute(.font, value: font, range: lineRange)
            storage.addAttribute(
                .foregroundColor, value: palette.markerColor,
                range: shifted(match.range(at: 1), by: lineRange.location)
            )
            styleInline(in: lineRange, storage: storage, text: text, palette: palette, baseFont: font)
            return
        }

        // Blockquote: soften the whole line, mark the ">".
        if let match = firstMatch(#"^(\s*>[ \t]?)"#, in: line) {
            storage.addAttribute(.foregroundColor, value: palette.quoteColor, range: lineRange)
            storage.addAttribute(.obliqueness, value: 0.12, range: lineRange)
            storage.addAttribute(
                .foregroundColor, value: palette.markerColor,
                range: shifted(match.range(at: 1), by: lineRange.location)
            )
            return
        }

        // List markers pick up the accent.
        if let match = firstMatch(#"^(\s*)([-*+]|\d{1,3}\.)([ \t])"#, in: line) {
            storage.addAttribute(
                .foregroundColor, value: palette.accentColor,
                range: shifted(match.range(at: 2), by: lineRange.location)
            )
        }

        styleInline(in: lineRange, storage: storage, text: text, palette: palette, baseFont: palette.baseFont)
    }

    // MARK: - Inline spans

    private static func styleInline(
        in lineRange: NSRange, storage: NSTextStorage, text: NSString,
        palette: Palette, baseFont: XFont
    ) {
        let line = text.substring(with: lineRange)
        let offset = lineRange.location

        // Bold+italic, bold, italic — ordered so longer markers win their range.
        enumerate(#"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#, in: line) { match in
            let font = boldFont(from: baseFont)
            storage.addAttribute(.font, value: font, range: shifted(match.range, by: offset))
            storage.addAttribute(.obliqueness, value: 0.16, range: shifted(match.range(at: 1), by: offset))
            dimMarkers(match, contentGroup: 1, offset: offset, storage: storage, palette: palette)
        }
        enumerate(#"(?<!\*)\*\*(?![\s*])(.+?)(?<![\s*])\*\*(?!\*)"#, in: line) { match in
            storage.addAttribute(.font, value: boldFont(from: baseFont), range: shifted(match.range, by: offset))
            dimMarkers(match, contentGroup: 1, offset: offset, storage: storage, palette: palette)
        }
        enumerate(#"(?<![\*\w])\*(?![\s*])([^*]+?)(?<![\s*])\*(?!\*)"#, in: line) { match in
            storage.addAttribute(.obliqueness, value: 0.16, range: shifted(match.range(at: 1), by: offset))
            dimMarkers(match, contentGroup: 1, offset: offset, storage: storage, palette: palette)
        }

        enumerate(#"~~(?=\S)(.+?)(?<=\S)~~"#, in: line) { match in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: shifted(match.range(at: 1), by: offset))
            dimMarkers(match, contentGroup: 1, offset: offset, storage: storage, palette: palette)
        }

        enumerate(#"`([^`]+)`"#, in: line) { match in
            storage.addAttribute(.backgroundColor, value: palette.codeBackground, range: shifted(match.range, by: offset))
            storage.addAttribute(.foregroundColor, value: palette.accentColor, range: shifted(match.range(at: 1), by: offset))
            dimMarkers(match, contentGroup: 1, offset: offset, storage: storage, palette: palette)
        }

        // Links: label in accent, target dimmed.
        enumerate(#"\[([^\]]+)\]\(([^)]+)\)"#, in: line) { match in
            storage.addAttribute(.foregroundColor, value: palette.markerColor, range: shifted(match.range, by: offset))
            storage.addAttribute(.foregroundColor, value: palette.accentColor, range: shifted(match.range(at: 1), by: offset))
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: shifted(match.range(at: 1), by: offset))
        }
    }

    /// Fade every part of the match that is not the content group.
    private static func dimMarkers(
        _ match: NSTextCheckingResult, contentGroup: Int, offset: Int,
        storage: NSTextStorage, palette: Palette
    ) {
        let whole = match.range
        let content = match.range(at: contentGroup)
        let leading = NSRange(location: whole.location, length: content.location - whole.location)
        let trailing = NSRange(location: NSMaxRange(content), length: NSMaxRange(whole) - NSMaxRange(content))
        if leading.length > 0 {
            storage.addAttribute(.foregroundColor, value: palette.markerColor, range: shifted(leading, by: offset))
        }
        if trailing.length > 0 {
            storage.addAttribute(.foregroundColor, value: palette.markerColor, range: shifted(trailing, by: offset))
        }
    }

    // MARK: - Fonts

    private static func headingFont(level: Int, base: XFont) -> XFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.5
        case 2: scale = 1.3
        case 3: scale = 1.15
        default: scale = 1.0
        }
        return bold(base, size: base.pointSize * scale)
    }

    private static func boldFont(from base: XFont) -> XFont { bold(base, size: base.pointSize) }

    /// The bold face of `base`'s own family at `size`, so a proportional base stays proportional.
    private static func bold(_ base: XFont, size: CGFloat) -> XFont {
        #if canImport(AppKit)
        let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.bold))
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.boldSystemFont(ofSize: size)
        #else
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitBold)) else {
            return UIFont.boldSystemFont(ofSize: size)
        }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }

    // MARK: - Regex helpers

    /// Every pattern the styler uses, compiled once.
    private static let regexes: [String: NSRegularExpression] = {
        let patterns = [
            #"(?<![\*\w])\*(?![\s*])([^*]+?)(?<![\s*])\*(?!\*)"#,
            #"(?<!\*)\*\*(?![\s*])(.+?)(?<![\s*])\*\*(?!\*)"#,
            #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#,
            #"\[([^\]]+)\]\(([^)]+)\)"#,
            #"^(#{1,6})[ \t]"#,
            #"^(\s*)([-*+]|\d{1,3}\.)([ \t])"#,
            #"^(\s*>[ \t]?)"#,
            #"`([^`]+)`"#,
            #"~~(?=\S)(.+?)(?<=\S)~~"#,
        ]
        var compiled: [String: NSRegularExpression] = [:]
        for pattern in patterns { compiled[pattern] = try? NSRegularExpression(pattern: pattern) }
        return compiled
    }()

    private static func regex(_ pattern: String) -> NSRegularExpression? { regexes[pattern] }

    private static func firstMatch(_ pattern: String, in line: String) -> NSTextCheckingResult? {
        regex(pattern)?.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private static func enumerate(_ pattern: String, in line: String, _ body: (NSTextCheckingResult) -> Void) {
        regex(pattern)?
            .matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            .forEach(body)
    }

    private static func shifted(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }

    private static func trimmedRange(of lineRange: NSRange, line: String) -> NSRange {
        let trailing = line.reversed().prefix { $0 == "\n" || $0 == "\r" }.count
        return NSRange(location: lineRange.location, length: max(0, lineRange.length - trailing))
    }
}
