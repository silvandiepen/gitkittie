import Foundation

/// Readable plain text from mail HTML, for search, snippets and the derived Markdown of
/// HTML-only messages. It reads the same token stream as the sanitizer and keeps only text:
/// nothing from `script`, `style`, `head` or `title`, no markup, no URLs.
public enum HTMLText {
    /// Elements that start a new line.
    static let lineElements: Set<String> = ["br", "li", "tr", "dt", "dd", "div", "caption", "figcaption", "address", "center"]
    /// Elements that stand apart as paragraphs (an empty line before and after).
    static let paragraphElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table", "ul", "ol", "dl", "hr", "section", "article",
        "header", "footer", "figure", "main", "nav",
    ]
    static let skippedElements: Set<String> = ["svg", "math", "template", "object", "noembed", "noframes", "select"]

    public static func plainText(fromHTML html: String) -> String {
        var lines: [String] = []
        var current = ""
        var skipDepth = 0
        var inHead = false

        func flush() {
            let collapsed = current.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{00A0}" })
                .joined(separator: " ")
            if !collapsed.isEmpty { lines.append(collapsed) }
            current = ""
        }
        func paragraph() {
            flush()
            if let last = lines.last, !last.isEmpty { lines.append("") }
        }

        for token in HTMLTokenizer.tokenize(html) {
            switch token {
            case .text(let text):
                if skipDepth == 0 && !inHead { current += text }
            case .rawText:
                continue // script, style, title, textarea: never text a reader saw
            case .startTag(let name, _, let selfClosing):
                if name == "head" { inHead = true }
                if name == "body" { inHead = false }
                if skippedElements.contains(name), !selfClosing { skipDepth += 1 }
                if paragraphElements.contains(name) { paragraph() } else if lineElements.contains(name) { flush() }
                if name == "li" { current += "• " }
                if name == "td" || name == "th" { current += " " }
            case .endTag(let name):
                if name == "head" { inHead = false }
                if skippedElements.contains(name) { skipDepth = max(0, skipDepth - 1) }
                if paragraphElements.contains(name) { paragraph() } else if lineElements.contains(name) { flush() }
            case .comment, .doctype:
                continue
            }
        }
        flush()
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
