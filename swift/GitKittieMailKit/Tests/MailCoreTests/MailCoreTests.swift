import XCTest
@testable import MailCore

final class MailCoreTests: XCTestCase {
    func testAccountIDsAreUniqueAndStable() {
        let a = MailAccountID(), b = MailAccountID()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(MailAccountID(a.rawValue), a)
    }
}
