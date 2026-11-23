import XCTest
@testable import GitKittieKit

final class CommitSplitPlanTests: XCTestCase {
    private let candidates = [
        CommitSplitCandidate(id: 1, hunkID: "a.swift:0", path: "a.swift", excerpt: "+a"),
        CommitSplitCandidate(id: 2, hunkID: "a.swift:1", path: "a.swift", excerpt: "+b"),
        CommitSplitCandidate(id: 3, hunkID: "README.md:0", path: "README.md", excerpt: "+c"),
    ]

    func testEveryChangeLandsInExactlyOneCommit() {
        let plan = CommitSplitPlan.normalize(
            groups: [("Fix the parser", [1, 2, 2]), ("Document it", [2, 3])],
            candidates: candidates)
        XCTAssertEqual(plan.map(\.message), ["Fix the parser", "Document it"])
        XCTAssertEqual(plan.map(\.hunkIDs), [["a.swift:0", "a.swift:1"], ["README.md:0"]])
    }

    func testUnknownNumbersAreDroppedAndUnclaimedChangesCollected() {
        let plan = CommitSplitPlan.normalize(groups: [("Fix the parser", [1, 99])], candidates: candidates)
        XCTAssertEqual(plan.map(\.message), ["Fix the parser", "Remaining changes"])
        XCTAssertEqual(plan.last?.hunkIDs, ["a.swift:1", "README.md:0"])
    }

    func testOneGroupIsNotASplit() {
        XCTAssertTrue(CommitSplitPlan.normalize(groups: [("All of it", [1, 2, 3])], candidates: candidates).isEmpty)
    }

    func testCandidatesSkipHunksWithoutChanges() {
        let diffs = [GitFileDiff(path: "a.swift", hunks: [
            GitHunk(id: "a.swift:0", header: "@@ -1 +1 @@", lines: ["-x", "+y"]),
            GitHunk(id: "a.swift:1", header: "@@ -5 +5 @@", lines: [" same"]),
        ])]
        XCTAssertEqual(CommitSplitCandidate.candidates(from: diffs).map(\.hunkID), ["a.swift:0"])
    }
}
