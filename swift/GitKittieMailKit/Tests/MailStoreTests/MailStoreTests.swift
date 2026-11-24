import XCTest
import MailTestSupport

final class MailStoreTests: XCTestCase {
    func testFixturesAreBundled() throws {
        XCTAssertNotNil(MailFixtures.directory)
    }
}
