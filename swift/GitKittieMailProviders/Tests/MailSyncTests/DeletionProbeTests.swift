import XCTest
import MailCore
import MailStore
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

    // MARK: - Back-off for a candidate the check could not decide (GKM-076, MAIL-105)

    func testACandidateThatCouldNotBeDecidedWaitsLongerEachTimeUpToTheLimit() throws {
        let id = MailMessageID()
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        let backoff: ClosedRange<Duration> = .seconds(600) ... .seconds(3_600)
        func candidate(_ undecided: Int) -> DeletionCandidate {
            DeletionCandidate(id: id, messageID: nil, noticedAt: checked.addingTimeInterval(-60),
                              checkedAt: undecided == 0 ? nil : checked, undecidedChecks: undecided)
        }
        func due(_ undecided: Int, after seconds: TimeInterval) -> Bool {
            SyncCoordinator.isDue(candidate(undecided), at: checked.addingTimeInterval(seconds), backoff: backoff)
        }
        XCTAssertTrue(due(0, after: 0), "never undecided: checked at once")
        XCTAssertFalse(due(1, after: 599))
        XCTAssertTrue(due(1, after: 600))
        XCTAssertFalse(due(2, after: 1_199))
        XCTAssertTrue(due(2, after: 1_200))
        XCTAssertFalse(due(3, after: 2_399))
        XCTAssertTrue(due(3, after: 2_400))
        XCTAssertFalse(due(4, after: 3_599), "the limit")
        XCTAssertTrue(due(4, after: 3_600))
        XCTAssertTrue(due(1_000, after: 3_600), "many undecided checks still wait only the limit")
        XCTAssertTrue(due(1, after: -60), "a clock set back does not hold it up")
    }
}
