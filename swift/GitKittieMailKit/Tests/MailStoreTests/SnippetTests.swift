import XCTest
@testable import MailStore

/// GKM-040: the list snippet stops reading the body after 200 Characters, and must be exactly
/// what collapsing the whole body and keeping 200 gave.
final class SnippetTests: XCTestCase {
    private func reference(_ body: String) -> String {
        String(body.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    func testTheSnippetIsTheCollapsedBodysFirst200Characters() {
        var bodies = [
            "", " ", "\r\n\t ", "one", "  leading and trailing  ", "a\r\nb\n\nc\t\td",
            String(repeating: "word ", count: 100), String(repeating: "x", count: 500), String(repeating: "ab ", count: 67) + "tail",
            // Characters that join across what follows: flags, emoji sequences, combining marks.
            String(repeating: "🇳🇱", count: 120), String(repeating: "e\u{0301} ", count: 150), String(repeating: "👩‍👩‍👧 ", count: 150),
            String(repeating: "a", count: 199) + "e\u{0301}\u{0308} more", String(repeating: "あいう\u{3000}", count: 80),
            "\u{00A0}non-breaking\u{00A0}spaces\u{2028}and separators " + String(repeating: "Ωμέγα ", count: 60),
        ]
        var random = SystemRandomNumberGenerator()
        let pieces = ["a", "bc", " ", "  ", "\n", "\r\n", "\t", "é", "e\u{0301}", "🇳🇱", "\u{200D}", "日本", "\u{00A0}", "x\u{0308}"]
        for _ in 0..<500 {
            bodies.append((0..<Int.random(in: 0...400, using: &random)).map { _ in pieces.randomElement(using: &random)! }.joined())
        }
        for body in bodies {
            XCTAssertEqual(IndexRecord.snippet(of: body), reference(body), body.debugDescription)
        }
    }
}
