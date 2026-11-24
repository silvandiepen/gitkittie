import XCTest
import MailTestSupport

final class MailClassifierTests: XCTestCase {
    func testFixturesAreBundled() throws {
        XCTAssertNotNil(MailFixtures.directory)
    }
}
