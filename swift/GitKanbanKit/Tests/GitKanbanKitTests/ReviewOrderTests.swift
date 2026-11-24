import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// Review requests are listed newest first, so the one an agent just asked for is on top.
final class ReviewOrderTests: XCTestCase {
    private func request(_ id: String, at date: String?) -> ReviewRequest {
        let stamp = date.map { "requested_at: \($0)\n" } ?? ""
        return Review.parse("---\nid: \(id)\ntitle: \(id)\n\(stamp)items: []\n---\n", folder: id)
    }

    func testNewestFirstWithUndatedLast() {
        let requests = [
            request("old", at: "2026-11-01T10:00:00Z"),
            request("undated-a", at: nil),
            request("new", at: "2026-11-23T10:00:00Z"),
            request("undated-b", at: nil),
            request("middle", at: "2026-11-10T10:00:00Z"),
        ]
        XCTAssertEqual(AppModel.newestFirst(requests).map(\.id), ["new", "middle", "old", "undated-a", "undated-b"])
    }
}
