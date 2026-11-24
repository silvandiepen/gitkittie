import Foundation

/// The URLs the reader uses inside a rendered message. One custom scheme, served only by the
/// reader's own handler: the document itself and the message's inline (`cid:`) parts. Links
/// never point at their real destination inside the web view; they point at `x-gkm-link:<n>`
/// and the app shows the real destination before anything opens (ThreatModel §2).
public enum ReaderURLs {
    public static let scheme = "gkm-mail"
    public static let document = "gkm-mail://message/document"
    public static let contentIDPrefix = "gkm-mail://message/cid/"
    public static let linkScheme = "x-gkm-link"

    public static func contentID(_ cid: String) -> String {
        contentIDPrefix + (cid.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
    }

    /// The content id a `gkm-mail://message/cid/…` URL names, or nil for any other URL.
    public static func contentID(in url: URL) -> String? {
        let string = url.absoluteString
        guard string.hasPrefix(contentIDPrefix) else { return nil }
        return String(string.dropFirst(contentIDPrefix.count)).removingPercentEncoding
    }

    public static func link(_ index: Int) -> String { "\(linkScheme):\(index)" }

    /// The link index an `x-gkm-link:<n>` URL names.
    public static func linkIndex(in url: URL) -> Int? {
        guard url.scheme == linkScheme else { return nil }
        return Int(url.absoluteString.dropFirst(linkScheme.count + 1))
    }

    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

/// A link found in a message: where it really goes, and what it showed.
public struct HTMLLink: Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    /// The `href` as written (character references decoded), trimmed.
    public var href: String
    /// The text the link showed, whitespace collapsed.
    public var text: String
    /// False for schemes the reader never opens (`javascript:`, `data:`, `file:`, app schemes).
    public var isAllowedScheme: Bool

    public init(index: Int, href: String, text: String, isAllowedScheme: Bool) {
        self.index = index
        self.href = href
        self.text = text
        self.isAllowedScheme = isAllowedScheme
    }
}

/// What the sanitizer did and found, for the reader's notices and for tests.
public struct SanitizedHTML: Equatable, Sendable {
    /// A complete document, safe to hand to the locked-down web view.
    public var document: String
    /// The Content-Security-Policy the document carries (also sent as a response header).
    public var contentSecurityPolicy: String
    public var links: [HTMLLink]
    /// Remote images present in the message (loaded or not).
    public var remoteImages: Int
    /// Remote references removed: images (unless allowed), CSS `url()`, `@import`, backgrounds.
    public var blockedRemoteReferences: Int
    /// Images that look like tracking pixels. Never fetched, even with remote images allowed.
    public var trackingPixels: Int
    /// Scripts, frames, plug-ins, event handlers and other active content removed.
    public var removedActiveContent: Int
    public var hasForms: Bool
    public var hasPasswordField: Bool
    /// `cid:` references the document uses.
    public var contentIDs: Set<String>
}

/// Turns hostile mail HTML into a document that can do nothing but display (ThreatModel §1).
///
/// It is an allowlist re-serializer: every element and attribute is dropped unless listed
/// here, text is re-escaped, and URLs are rewritten. It is the first of four independent
/// layers; the reader also disables JavaScript, blocks every load outside its own scheme with
/// a content rule list, sends a `default-src 'none'` CSP, and refuses every navigation.
public enum HTMLSanitizer {
    public struct Policy: Sendable {
        /// The user chose to load remote images for this sender or message. Tracking pixels,
        /// CSS references, fonts and everything else stay blocked regardless.
        public var allowRemoteImages: Bool
        /// The message's inline parts; `cid:` references to anything else are dropped.
        public var contentIDs: Set<String>
        public init(allowRemoteImages: Bool = false, contentIDs: Set<String> = []) {
            self.allowRemoteImages = allowRemoteImages
            self.contentIDs = contentIDs
        }
    }

    public static func sanitize(_ html: String, policy: Policy = Policy()) -> SanitizedHTML {
        var state = State(policy: policy)
        let tokens = HTMLTokenizer.tokenize(html)
        for token in tokens { state.consume(token) }
        state.closeOpenLink()
        let csp = contentSecurityPolicy(allowRemoteImages: policy.allowRemoteImages)
        let document = """
            <!DOCTYPE html><html><head><meta charset="utf-8">\
            <meta http-equiv="Content-Security-Policy" content="\(CharacterReferences.escape(csp))">\
            <meta name="referrer" content="no-referrer"><style>\(readerCSS)</style>\(state.head)</head>\
            <body>\(state.body)</body></html>
            """
        return SanitizedHTML(document: document, contentSecurityPolicy: csp, links: state.links,
                             remoteImages: state.remoteImages, blockedRemoteReferences: state.blocked,
                             trackingPixels: state.trackingPixels, removedActiveContent: state.removedActive,
                             hasForms: state.hasForms, hasPasswordField: state.hasPasswordField, contentIDs: state.usedContentIDs)
    }

    public static func contentSecurityPolicy(allowRemoteImages: Bool) -> String {
        let images = allowRemoteImages ? "\(ReaderURLs.scheme): data: https: http:" : "\(ReaderURLs.scheme): data:"
        return "default-src 'none'; img-src \(images); style-src 'unsafe-inline'; font-src 'none'; script-src 'none'; "
            + "object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; connect-src 'none'; media-src 'none'; "
            + "manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
    }

    /// The page around the message: white paper, readable type, nothing that loads.
    static let readerCSS = """
        :root{color-scheme:light}html{background:#fff}body{margin:0;padding:20px 24px;font:14px/1.5 -apple-system,\
        BlinkMacSystemFont,sans-serif;color:#1d1d1f;background:#fff;overflow-wrap:anywhere}img{max-width:100%;height:auto}\
        a{color:#0b57d0}table{max-width:100%}pre{white-space:pre-wrap}
        """

    // MARK: Allowlists

    static let allowedElements: Set<String> = [
        "a", "abbr", "address", "article", "aside", "b", "bdi", "big", "blockquote", "br", "caption", "center", "cite", "code",
        "col", "colgroup", "dd", "del", "details", "dfn", "div", "dl", "dt", "em", "figcaption", "figure", "font", "footer",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "i", "img", "ins", "kbd", "label", "li", "main", "mark", "nav",
        "ol", "p", "pre", "q", "s", "samp", "section", "small", "span", "strike", "strong", "sub", "summary", "sup", "table",
        "tbody", "td", "tfoot", "th", "thead", "time", "tr", "tt", "u", "ul", "var", "wbr",
    ]

    /// Removed together with everything inside them.
    static let droppedWithContent: Set<String> = [
        "script", "iframe", "frame", "frameset", "object", "applet", "svg", "math", "template", "audio", "video", "canvas",
        "select", "datalist", "textarea", "title", "noembed", "noframes", "xmp", "plaintext", "map", "portal", "dialog",
    ]

    /// Active content: counted when removed, so the reader can say it took something out.
    static let activeElements: Set<String> = [
        "script", "iframe", "frame", "frameset", "object", "embed", "applet", "svg", "math", "template", "audio", "video",
        "canvas", "portal", "meta", "base", "link",
    ]

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr", "keygen",
    ]

    static let allowedAttributes: Set<String> = [
        "align", "valign", "bgcolor", "color", "width", "height", "border", "cellpadding", "cellspacing", "colspan",
        "rowspan", "dir", "lang", "title", "style", "class", "face", "size", "span", "start", "type", "reversed", "alt",
        "nowrap", "summary", "headers", "scope", "abbr", "datetime", "hspace", "vspace", "frame", "rules", "open",
    ]

    // MARK: State

    struct State {
        let policy: Policy
        var head = ""
        var body = ""
        var links: [HTMLLink] = []
        var remoteImages = 0
        var blocked = 0
        var trackingPixels = 0
        var removedActive = 0
        var hasForms = false
        var hasPasswordField = false
        var usedContentIDs: Set<String> = []
        /// Inside an element removed with its content: its name and nesting depth.
        var skipping: (name: String, depth: Int)?
        /// The open `<a>` collecting its visible text.
        var openLink: Int?
        var linkText = ""
        var inHead = false

        init(policy: Policy) { self.policy = policy }

        mutating func emit(_ html: String) {
            if inHead { head += html } else { body += html }
        }

        mutating func consume(_ token: HTMLToken) {
            if let skip = skipping {
                switch token {
                case .startTag(let name, _, let selfClosing) where name == skip.name && !selfClosing && !voidElements.contains(name):
                    skipping = (skip.name, skip.depth + 1)
                case .endTag(let name) where name == skip.name:
                    skipping = skip.depth <= 1 ? nil : (skip.name, skip.depth - 1)
                default: break
                }
                return
            }
            switch token {
            case .doctype, .comment:
                return
            case .text(let text):
                if openLink != nil { linkText += text }
                // Text in <head> outside <style> is not displayed by browsers; keep it in the body.
                body += CharacterReferences.escape(text)
            case .rawText(let element, let text):
                if element == "style" {
                    let result = CSSSanitizer.sanitize(text, resolveContentID: resolve)
                    blocked += result.blockedReferences
                    usedContentIDs.formUnion(result.contentIDs)
                    emit("<style>\(result.css)</style>")
                }
                // Every other raw-text element is dropped with its content (see startTag).
            case .startTag(let name, let attributes, let selfClosing):
                startTag(name, attributes, selfClosing: selfClosing)
            case .endTag(let name):
                endTag(name)
            }
        }

        mutating func startTag(_ name: String, _ attributes: [HTMLAttribute], selfClosing: Bool) {
            if attributes.contains(where: { $0.name.hasPrefix("on") }) { removedActive += 1 }
            switch name {
            case "head": inHead = true; return
            case "body", "html": inHead = false; return
            case "style": return // its rawText token follows
            case "form": hasForms = true; return
            case "input", "button", "keygen", "option", "optgroup", "fieldset", "legend":
                if name == "input" {
                    hasForms = true
                    if attributes.first(where: { $0.name == "type" })?.value.lowercased() == "password" { hasPasswordField = true }
                }
                return
            case "img":
                image(attributes)
                return
            case "a":
                anchor(attributes)
                return
            default: break
            }
            if activeElements.contains(name) { removedActive += 1 }
            if name == "link" || name == "meta" || name == "base" { return }
            if droppedWithContent.contains(name) {
                // Raw-text elements arrive as start + rawText + end tokens; skipping covers both.
                if !selfClosing && !voidElements.contains(name) { skipping = (name, 1) }
                return
            }
            guard allowedElements.contains(name) else { return } // unknown: tag dropped, content kept
            emit("<\(name)\(serialize(attributes))>")
        }

        mutating func endTag(_ name: String) {
            switch name {
            case "head": inHead = false; return
            case "a":
                closeOpenLink()
                return
            default: break
            }
            guard allowedElements.contains(name), !voidElements.contains(name) else { return }
            emit("</\(name)>")
        }

        // MARK: Elements with URLs

        mutating func anchor(_ attributes: [HTMLAttribute]) {
            closeOpenLink()
            let rest = attributes.filter { $0.name != "href" && $0.name != "title" }
            guard let raw = attributes.first(where: { $0.name == "href" })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, !raw.hasPrefix("#") else {
                // No destination (or an in-page anchor): the text stays, the link does not.
                openLink = nil
                return
            }
            let allowed = HTMLSanitizer.isAllowedLinkScheme(raw)
            let index = links.count
            links.append(HTMLLink(index: index, href: raw, text: "", isAllowedScheme: allowed))
            openLink = index
            linkText = ""
            // The title shows the real destination on hover; the href only names the link.
            let title = allowed ? raw : "Blocked link: \(raw)"
            body += "<a href=\"\(ReaderURLs.link(index))\" title=\"\(CharacterReferences.escape(String(title.prefix(2_000))))\"\(serialize(rest))>"
        }

        mutating func closeOpenLink() {
            guard let index = openLink else { return }
            links[index].text = linkText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            openLink = nil
            linkText = ""
            body += "</a>"
        }

        mutating func image(_ attributes: [HTMLAttribute]) {
            var kept = attributes.filter { allowedAttributes.contains($0.name) && $0.name != "style" }
            if let style = attributes.first(where: { $0.name == "style" })?.value {
                let result = CSSSanitizer.sanitizeDeclarations(style, resolveContentID: resolve)
                blocked += result.blockedReferences
                usedContentIDs.formUnion(result.contentIDs)
                kept.append(HTMLAttribute(name: "style", value: result.css))
            }
            if attributes.contains(where: { $0.name == "srcset" || $0.name == "lowsrc" || $0.name == "dynsrc" }) { blocked += 1 }
            let src = attributes.first(where: { $0.name == "src" })?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lower = src.lowercased()
            var source: String?
            if lower.hasPrefix("cid:") {
                source = resolve(String(src.dropFirst(4)))
                if source != nil { usedContentIDs.insert(String(src.dropFirst(4))) }
            } else if HTMLSanitizer.isInlineImageData(lower) {
                source = src
            } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//") {
                remoteImages += 1
                if HTMLSanitizer.looksLikeTrackingPixel(attributes) {
                    trackingPixels += 1
                    blocked += 1
                } else if policy.allowRemoteImages {
                    source = lower.hasPrefix("//") ? "https:" + src : src
                } else {
                    blocked += 1
                }
            } else if !src.isEmpty {
                blocked += 1
            }
            if let source { kept.append(HTMLAttribute(name: "src", value: source)) }
            emit("<img\(serialize(kept, alreadyFiltered: true))>")
        }

        func resolve(_ cid: String) -> String? {
            let id = cid.trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
            let decoded = id.removingPercentEncoding ?? id
            guard policy.contentIDs.contains(decoded) else { return nil }
            return ReaderURLs.contentID(decoded)
        }

        mutating func serialize(_ attributes: [HTMLAttribute], alreadyFiltered: Bool = false) -> String {
            var out = ""
            for attribute in attributes where alreadyFiltered || allowedAttributes.contains(attribute.name) {
                var value = attribute.value
                if attribute.name == "style", !alreadyFiltered {
                    let result = CSSSanitizer.sanitizeDeclarations(value, resolveContentID: resolve)
                    blocked += result.blockedReferences
                    usedContentIDs.formUnion(result.contentIDs)
                    value = result.css
                }
                out += " \(attribute.name)=\"\(CharacterReferences.escape(value))\""
            }
            if !alreadyFiltered, attributes.contains(where: { $0.name == "background" }) { blocked += 1 }
            return out
        }
    }

    // MARK: Classification helpers

    static func isAllowedLinkScheme(_ href: String) -> Bool {
        // Browsers ignore ASCII whitespace and control characters inside a scheme ("java\tscript:").
        let cleaned = href.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }
        let lower = String(String.UnicodeScalarView(cleaned)).lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("mailto:")
    }

    static func isInlineImageData(_ lowercasedSource: String) -> Bool {
        ["data:image/png", "data:image/jpeg", "data:image/jpg", "data:image/gif", "data:image/webp"].contains { lowercasedSource.hasPrefix($0) }
            && lowercasedSource.utf8.count <= 2 * 1024 * 1024
    }

    /// A remote image that is tiny, hidden, or named like a beacon.
    static func looksLikeTrackingPixel(_ attributes: [HTMLAttribute]) -> Bool {
        func dimension(_ name: String) -> Int? {
            attributes.first(where: { $0.name == name }).flatMap { Int($0.value.trimmingCharacters(in: CharacterSet(charactersIn: " px"))) }
        }
        if let width = dimension("width"), width <= 3 { return true }
        if let height = dimension("height"), height <= 3 { return true }
        let style = (attributes.first(where: { $0.name == "style" })?.value ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if style.contains("display:none") || style.contains("visibility:hidden") || style.contains("opacity:0")
            || style.range(of: #"(^|;)(width|height):[0-3](px)?(;|$)"#, options: .regularExpression) != nil { return true }
        let src = (attributes.first(where: { $0.name == "src" })?.value ?? "").lowercased()
        return ["/open?", "/open.", "pixel", "beacon", "/track", "/o.gif", "/wf/open"].contains { src.contains($0) }
    }
}
