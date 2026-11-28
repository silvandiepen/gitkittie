import GitKittieKit
import XCTest
@testable import GitKanbanKit

/// The app's side of review pushes: reading a push's payload, the id a push and the app's
/// own check share, and which requests the app still announces itself.
@MainActor
final class ReviewPushTests: XCTestCase {
    func testReadsTheReviewAPushNames() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Review: Pet models"]],
            "review": ["repo": "octo/tasks", "folder": "Morrow/review/M-1", "path": "Morrow/review/M-1/review.md",
                       "id": "M-1", "board": "Morrow", "level": "urgent"],
        ]
        let review = PushedReview(userInfo: userInfo)
        XCTAssertEqual(review, PushedReview(repo: "octo/tasks", folder: "Morrow/review/M-1", id: "M-1", board: "Morrow", level: .urgent))
        XCTAssertEqual(review?.ref, ReviewRef(origin: "octo/tasks", folder: "Morrow/review/M-1"))
        XCTAssertNil(PushedReview(userInfo: ["aps": ["content-available": 1], "reviewsChanged": ["repo": "group/tasks"]]))
        // What the app posts itself reads back the same.
        XCTAssertEqual(PushedReview(userInfo: review!.userInfo), review)
    }

    func testSharesTheNotificationIDWithTheRelay() {
        // The same vector as the relay's test (collapseID in apps/gitkanban-relay/src/apns.ts).
        XCTAssertEqual(reviewNotificationID(repo: "octo/tasks", folder: "Morrow/review/MORROW-182-pet-models"),
                       "review-7c36cbb94ad4b1625df16e2c72184938")
    }

    func testAnnouncesOnlyWhatNoPushToldAndAtTheLevelAskedFor() {
        func request(_ folder: String, _ notify: ReviewNotify) -> ReviewRequest {
            var request = Review.parse("---\nnotify: \(notify.rawValue)\nitems:\n  - file: a.png\n---\n", folder: folder)
            request.origin = "octo/tasks"
            return request
        }
        let urgent = request("M/review/a", .urgent), normal = request("M/review/b", .normal)
        let silent = request("M/review/c", .silent), pushed = request("M/review/d", .normal)
        let shown = request("M/review/e", .normal)
        let all = [urgent, normal, silent, pushed, shown]
        let pushedIDs: Set = [reviewNotificationID(repo: "octo/tasks", folder: "M/review/d")]
        let delivered: Set = [reviewNotificationID(repo: "octo/tasks", folder: "M/review/e")]

        let everything = AppModel.toAnnounce(all, pushed: pushedIDs, delivered: delivered) { AppModel.announces($0, urgentOnly: false) }
        XCTAssertEqual(everything.map(\.folder), ["M/review/a", "M/review/b"])
        let urgentOnly = AppModel.toAnnounce(all, pushed: pushedIDs, delivered: delivered) { AppModel.announces($0, urgentOnly: true) }
        XCTAssertEqual(urgentOnly.map(\.folder), ["M/review/a"])
    }
}
