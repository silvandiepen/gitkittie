import Foundation
import XCTest
@testable import MailClassifier

/// GKM-040: `TemplateText` is only quicker. It must answer exactly as `String.contains`, which
/// is what the rule set means by a template term being in the subject or body.
final class TemplateTextTests: XCTestCase {
    private static let allTerms = Templates.securityCode + Templates.securityAlert + Templates.delivery + Templates.transaction
        + Templates.transactionDue + Templates.transactionAction + Templates.promotion + Templates.newsletter + Templates.spamPhrases

    func testAgreesWithStringContainsOnEveryTermAndAwkwardText() {
        let decomposed = { (text: String) in text.decomposedStringWithCanonicalMapping }
        var texts = [
            "", "your code is 123456", "Your Code", "you have won the lottery\r\nclaim your prize",
            // The same words in the other normal form, and with marks the term does not have.
            decomposed("ihr bestätigungscode lautet 4821"), "ihr bestätigungscode lautet 4821",
            "ihr bestätigungscode\u{0301} lautet", "your code\u{0301} is here", "e\u{0301}lottery",
            // A term that ends inside a Character of the text (a combining mark follows).
            "verification code\u{0308}", "lotter\u{0079}\u{0308}",
            // Japanese with a dakuten written separately, and Greek with and without tonos.
            "認証コード: 1234", decomposed("認証コード: 1234"), "ワンタイムパスワード", "ワンタイム\u{3099}",
            "ο κωδικός επαλήθευσης σας", decomposed("ο κωδικός επαλήθευσης σας"), "ο κωδικος επαληθευσης σας",
            "κερδίσατε!", "当選しました", "u heeft gewonnen", "sie haben gewonnen\u{200D}",
            "flag 🇳🇱 your order", "café wire transfer", "wire\u{00A0}transfer", "inheritance\u{FE0F}",
        ]
        // Every term on its own, decomposed, and inside text, so a match is found where one exists.
        for term in Self.allTerms {
            texts.append(term)
            texts.append(decomposed(term))
            texts.append("re: " + term + " today")
            texts.append("x" + term.dropLast() + "\u{0301}")
        }
        var compared = 0
        for text in texts {
            let template = TemplateText(text)
            for term in Self.allTerms {
                XCTAssertEqual(template.contains(term), text.contains(term), "\(term.debugDescription) in \(text.debugDescription)")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 10_000)
    }

    func testFindsAnASCIITermInALongASCIIBodyAndNothingElse() {
        let body = String(repeating: "lorem ipsum dolor sit amet. ", count: 2_000) + "please send the processing fee by wire transfer."
        let text = TemplateText(body)
        XCTAssertEqual(Templates.spamPhrases.filter(text.contains), ["processing fee", "wire transfer"])
        XCTAssertEqual(Templates.spamPhrases.filter(body.contains), ["processing fee", "wire transfer"])
    }
}
