import XCTest
@testable import MailSync

/// How a hit's header is compared with the stored one (GKM-043, MAIL-104): every difference a
/// server may make must still read as the same message; another message must not.
final class DeletionProbeTests: XCTestCase {
    private let stored = Data("Date: Sun, 27 Sep 2026 03:50:23 +0200\r\nFrom: Ada <ada@example.com>\r\nSubject: an invoice\r\n  for September\r\n\r\nBody\r\nX-Not: a header\r\n".utf8)

    func testTheHeaderEndsAtTheFirstEmptyLineAndFoldedValuesAreUnfolded() {
        XCTAssertEqual(DeletionProbe.fields(of: stored),
                       ["date: Sun, 27 Sep 2026 03:50:23 +0200", "from: Ada <ada@example.com>", "subject: an invoice for September"])
    }

    func testAServersCopyWithoutTheClosingLineWithOtherFoldingOrAddedFieldsHasEveryStoredField() {
        let fields = DeletionProbe.fields(of: stored)
        let withoutEmptyLine = Data("Date: Sun, 27 Sep 2026 03:50:23 +0200\r\nFrom: Ada <ada@example.com>\r\nSubject: an invoice\r\n for September\r\n".utf8)
        XCTAssertTrue(fields.isSubset(of: DeletionProbe.fields(of: withoutEmptyLine)))
        let bareLFAddedFieldsOtherCase = Data("Message-ID: <added@server>\nFROM: Ada <ada@example.com>\ndate: Sun, 27 Sep 2026 03:50:23 +0200\nSubject: an invoice for\tSeptember\n\n".utf8)
        XCTAssertTrue(fields.isSubset(of: DeletionProbe.fields(of: bareLFAddedFieldsOtherCase)))
    }

    func testAnotherMessageFromTheSameSenderTheSameDayIsNot() {
        let other = Data("Date: Sun, 27 Sep 2026 03:50:23 +0200\r\nFrom: Ada <ada@example.com>\r\nSubject: a receipt\r\n".utf8)
        XCTAssertFalse(DeletionProbe.fields(of: stored).isSubset(of: DeletionProbe.fields(of: other)))
    }
}
