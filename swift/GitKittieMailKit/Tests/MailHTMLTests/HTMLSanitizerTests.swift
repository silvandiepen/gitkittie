import Foundation
import MailHTML
import MailTestSupport
import XCTest

final class HTMLSanitizerTests: XCTestCase {
    // MARK: Hostile fixtures

    /// Every hostile fixture: nothing active, nothing remote, survives in the output, checked
    /// both by re-tokenizing the output and by plain string search (so a tokenizer blind spot
    /// cannot hide a miss).
    func testHostileFixturesComeOutInert() throws {
        for url in try MailFixtures.hostileHTMLURLs() {
            let html = try XCTUnwrap(Self.html(of: Data(contentsOf: url)), url.lastPathComponent)
            let result = HTMLSanitizer.sanitize(html, policy: .init(allowRemoteImages: false, contentIDs: ["logo@cloudvault"]))
            Self.assertInert(result, allowRemoteImages: false, file: url.lastPathComponent)
        }
    }

    func testRemoteImagesAllowedLoadsImagesOnlyNeverPixelsOrCSS() throws {
        let html = try XCTUnwrap(Self.html(of: MailFixtures.hostileHTML("hostile-tracking-pixels.eml")))
        let result = HTMLSanitizer.sanitize(html, policy: .init(allowRemoteImages: true))
        Self.assertInert(result, allowRemoteImages: true, file: "pixels, remote allowed")
        XCTAssertTrue(result.document.contains(#"src="https://images.example.net/hero.png""#))
        XCTAssertFalse(result.document.contains("track.example.net"), "a tracking pixel is never loaded, even with remote images on")
        XCTAssertEqual(result.trackingPixels, 4)
        XCTAssertTrue(result.contentSecurityPolicy.contains("img-src gkm-mail: data: https: http:"))

        let css = try XCTUnwrap(Self.html(of: MailFixtures.hostileHTML("hostile-css-exfiltration.eml")))
        let cssResult = HTMLSanitizer.sanitize(css, policy: .init(allowRemoteImages: true))
        XCTAssertFalse(cssResult.document.contains("example.net"), "remote images do not unlock CSS references")
    }

    func testFindingsAreReported() throws {
        let scripts = HTMLSanitizer.sanitize(try XCTUnwrap(Self.html(of: MailFixtures.hostileHTML("hostile-script-variants.eml"))))
        XCTAssertTrue(scripts.hasForms)
        XCTAssertTrue(scripts.hasPasswordField)
        XCTAssertGreaterThanOrEqual(scripts.removedActiveContent, 10)
        XCTAssertTrue(scripts.document.contains("Hello Alex, this is the visible text."))
        XCTAssertTrue(scripts.document.contains("noscript text shows"), "with scripting off, noscript content is what people see")
        XCTAssertEqual(scripts.links.map(\.isAllowedScheme), [false, false, false])

        let pixels = HTMLSanitizer.sanitize(try XCTUnwrap(Self.html(of: MailFixtures.hostileHTML("hostile-tracking-pixels.eml"))))
        XCTAssertEqual(pixels.trackingPixels, 4)
        XCTAssertEqual(pixels.remoteImages, 7)
        XCTAssertGreaterThanOrEqual(pixels.blockedRemoteReferences, 8)

        let css = HTMLSanitizer.sanitize(try XCTUnwrap(Self.html(of: MailFixtures.hostileHTML("hostile-css-exfiltration.eml"))))
        XCTAssertGreaterThanOrEqual(css.blockedRemoteReferences, 15)
        XCTAssertTrue(css.document.contains("CSS exfiltration attempts. The text stays."))
    }

    func testLinksPointAtTheReaderAndShowTheirRealDestination() throws {
        let result = HTMLSanitizer.sanitize(#"<a href="https://shop.example.com/x?a=1&amp;b=2" target="_blank" ping="https://p.example.net">Shop <b>now</b></a>"#)
        XCTAssertEqual(result.links, [HTMLLink(index: 0, href: "https://shop.example.com/x?a=1&b=2", text: "Shop now", isAllowedScheme: true)])
        XCTAssertTrue(result.document.contains(#"<a href="x-gkm-link:0" title="https://shop.example.com/x?a=1&amp;b=2">Shop <b>now</b></a>"#),
                      result.document)
        XCTAssertFalse(result.document.contains("ping"))
        XCTAssertFalse(result.document.contains("target"))
    }

    func testInlineImagesUseTheReaderSchemeAndUnknownContentIDsAreDropped() {
        let result = HTMLSanitizer.sanitize(#"<img src="cid:logo@x"><img src="cid:missing@x"><p style="background:url(cid:logo@x)">"#,
                                            policy: .init(contentIDs: ["logo@x"]))
        XCTAssertTrue(result.document.contains(#"<img src="gkm-mail://message/cid/logo%40x">"#), result.document)
        XCTAssertTrue(result.document.contains("<img>"), "an unknown cid loses its source")
        XCTAssertTrue(result.document.contains(#"background:url(&quot;gkm-mail://message/cid/logo%40x&quot;)"#), result.document)
        XCTAssertEqual(result.contentIDs, ["logo@x"])
    }

    // MARK: CSS

    func testCSSEscapesCannotHideAURL() {
        let result = CSSSanitizer.sanitize(#"a{background:u\72 l(https://x.example.net/a)} b{background:\75\72\6c(https://x.example.net/b)}"#) { _ in nil }
        XCTAssertFalse(result.css.contains("example.net"), result.css)
        XCTAssertEqual(result.blockedReferences, 2)
    }

    func testCSSCannotCloseItsStyleElement() {
        let result = CSSSanitizer.sanitize("p{color:red}</style><script>x()</script>") { _ in nil }
        XCTAssertFalse(result.css.contains("<"), result.css)
    }

    func testCSSKeepsLayout() {
        let result = CSSSanitizer.sanitize("p { color: #333; margin: 0 auto } @media (max-width: 600px) { td { display:block } }") { _ in nil }
        XCTAssertEqual(result.css, "p { color: #333; margin: 0 auto } @media (max-width: 600px) { td { display:block } }")
        XCTAssertEqual(result.blockedReferences, 0)
    }

    // MARK: Tokenizer and text

    func testTokenizerReadsMailMarkup() {
        let tokens = HTMLTokenizer.tokenize(#"<P CLASS=a title='x > y' data-x="&lt;b&gt;">Caf&eacute; &amp; &#x1F600;<br/><!-- c --></p>"#)
        XCTAssertEqual(tokens, [
            .startTag(name: "p", attributes: [HTMLAttribute(name: "class", value: "a"), HTMLAttribute(name: "title", value: "x > y"),
                                              HTMLAttribute(name: "data-x", value: "<b>")], selfClosing: false),
            .text("Café & 😀"),
            .startTag(name: "br", attributes: [], selfClosing: true),
            .comment,
            .endTag(name: "p"),
        ])
    }

    func testRawTextElementsEndOnlyAtTheirOwnEndTag() {
        let tokens = HTMLTokenizer.tokenize("<script>if (a</b) {}</script ><p>x")
        XCTAssertEqual(tokens, [.startTag(name: "script", attributes: [], selfClosing: false), .rawText(element: "script", text: "if (a</b) {}"),
                                .endTag(name: "script"), .startTag(name: "p", attributes: [], selfClosing: false), .text("x")])
    }

    func testPlainTextFromHTML() {
        let text = HTMLText.plainText(fromHTML: """
            <html><head><title>T</title><style>p{color:red}</style></head><body>
            <h1>Order&nbsp;shipped</h1><p>Your order <b>4711</b> is on its way.</p>
            <ul><li>Tea</li><li>Cups</li></ul><script>var secret = 1</script>
            <table><tr><td>Total</td><td>€ 12,00</td></tr></table></body></html>
            """)
        XCTAssertEqual(text, "Order shipped\n\nYour order 4711 is on its way.\n\n• Tea\n• Cups\n\nTotal € 12,00")
    }

    func testAHugeNestedDocumentIsHandled() {
        let html = String(repeating: "<div>", count: 50_000) + "x" + String(repeating: "</div>", count: 50_000)
        let result = HTMLSanitizer.sanitize(html)
        XCTAssertTrue(result.document.contains(">x<"))
    }

    // MARK: Helpers

    static func html(of eml: Data) -> String? {
        // The fixtures are small and well-formed MIME; MailMIME is tested on its own. Here the
        // HTML part is located by hand so this target does not depend on the parser.
        let text = String(decoding: eml, as: UTF8.self)
        guard let start = text.range(of: "<html", options: .caseInsensitive) ?? text.range(of: "<!DOCTYPE", options: .caseInsensitive) else { return nil }
        if let boundaryEnd = text.range(of: "\r\n--=_lookalike_boundary-rel", range: start.lowerBound..<text.endIndex) {
            return String(text[start.lowerBound..<boundaryEnd.lowerBound])
        }
        return String(text[start.lowerBound...])
    }

    static func assertInert(_ result: SanitizedHTML, allowRemoteImages: Bool, file: String, line: UInt = #line) {
        let document = result.document
        // String-level checks, independent of the tokenizer.
        for pattern in [#"(?i)<\s*script"#, #"(?i)<\s*iframe"#, #"(?i)<\s*object"#, #"(?i)<\s*embed"#, #"(?i)<\s*svg"#, #"(?i)<\s*math"#,
                        #"(?i)<\s*form"#, #"(?i)<\s*input"#, #"(?i)<\s*button"#, #"(?i)<\s*base"#, #"(?i)<\s*link"#, #"(?i)<\s*video"#,
                        #"(?i)<\s*audio"#, #"(?i)<\s*source"#, #"(?i)<\s*template"#, #"(?i)<\s*textarea"#, #"(?i)http-equiv\s*=\s*"?refresh"#,
                        #"(?i)\son[a-z]+\s*="#, #"(?i)javascript:"#, #"(?i)@import"#, #"(?i)@font-face"#, #"(?i)expression\("#,
                        #"(?i)srcset"#, #"(?i)\sping="#, #"(?i)\sbackground="#, #"(?i)image-set"#, #"(?i)data-pwned"#] {
            // data-pwned may legitimately appear only inside escaped text or titles; never as markup.
            let ranges = document.ranges(of: pattern)
            for range in ranges where !Self.isInsideEscapedText(document, range) {
                let start = document.index(range.lowerBound, offsetBy: -30, limitedBy: document.startIndex) ?? document.startIndex
                XCTFail("\(file): \(pattern) survived: …\(String(document[start..<range.upperBound]))", line: line)
            }
        }
        // Token-level checks.
        for token in HTMLTokenizer.tokenize(document) {
            guard case .startTag(let name, let attributes, _) = token else { continue }
            for attribute in attributes {
                switch attribute.name {
                case "src":
                    let ok = attribute.value.hasPrefix("gkm-mail://message/cid/") || attribute.value.hasPrefix("data:image/")
                        || (allowRemoteImages && name == "img" && attribute.value.hasPrefix("http"))
                    XCTAssertTrue(ok, "\(file): <\(name) src=\(attribute.value)>", line: line)
                case "href":
                    XCTAssertTrue(attribute.value.hasPrefix("x-gkm-link:"), "\(file): href \(attribute.value)", line: line)
                case "style":
                    for match in attribute.value.ranges(of: #"(?i)url\("#) {
                        XCTAssertTrue(attribute.value[match.upperBound...].hasPrefix("\"gkm-mail:"), "\(file): style \(attribute.value)", line: line)
                    }
                case "http-equiv", "charset", "name", "content":
                    XCTAssertEqual(name, "meta", "\(file): \(attribute.name) on <\(name)>", line: line)
                default:
                    XCTAssertFalse(attribute.name.hasPrefix("on"), "\(file): \(attribute.name)", line: line)
                }
            }
            if name == "meta" {
                let equiv = attributes.first { $0.name == "http-equiv" }?.value.lowercased()
                XCTAssertTrue(equiv == nil || equiv == "content-security-policy", "\(file): meta \(attributes)", line: line)
            }
        }
        // Anything that names a remote host outside a link title is a reference that survived.
        // (Text may name a URL; that is words, not a reference. Titles show link destinations.)
        let remote = document.ranges(of: #"(?i)(https?:)?//[a-z0-9.-]+\.example\.(net|com|org)"#)
            .filter { !isInsideEscapedText(document, $0) }
        let unexpected = allowRemoteImages ? remote.filter { !document[$0].contains("images.example.net") } : remote
        XCTAssertTrue(unexpected.isEmpty, "\(file): remote reference \(unexpected.map { String(document[$0]) })", line: line)
    }

    /// True when a match sits in an attribute value or text, i.e. it was escaped, not markup.
    /// Only `title` values and text can hold arbitrary sender words.
    static func isInsideEscapedText(_ document: String, _ range: Range<String.Index>) -> Bool {
        let before = document[..<range.lowerBound]
        guard let lastOpen = before.lastIndex(of: "<") else { return true }
        let lastClose = before.lastIndex(of: ">")
        if let lastClose, lastClose > lastOpen { return !document[range].hasPrefix("<") }
        // Inside a tag: inside a quoted title value?
        let tag = document[lastOpen..<range.lowerBound]
        return tag.range(of: #"title="[^"]*$"#, options: .regularExpression) != nil
    }
}

extension String {
    func ranges(of pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { Range($0.range, in: self) }
    }
}
