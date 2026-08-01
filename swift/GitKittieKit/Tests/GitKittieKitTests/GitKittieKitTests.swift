import XCTest
@testable import GitKittieKit

final class GitKittieKitTests: XCTestCase {
    func testPullResultDefaults() {
        let result = PullResult(updated: true)
        XCTAssertTrue(result.updated)
        XCTAssertTrue(result.conflicts.isEmpty)
    }
}
