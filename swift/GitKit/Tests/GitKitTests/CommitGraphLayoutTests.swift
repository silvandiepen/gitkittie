import XCTest
@testable import GitKit

final class CommitGraphLayoutTests: XCTestCase {
    func testLinearHistoryStaysInOneLane() {
        let rows = layoutCommitGraph([
            node("c", parents: ["b"]),
            node("b", parents: ["a"]),
            node("a", parents: [])
        ])

        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.colorIndex), [0, 0, 0])
        XCTAssertEqual(rows.map(\.laneCount), [1, 1, 1])
        XCTAssertEqual(rows.map(\.hasChildAbove), [false, true, true])
        XCTAssertEqual(rows.map(\.hasParentBelow), [true, true, false])
        XCTAssertTrue(rows.allSatisfy { $0.edges.isEmpty })
    }

    func testMergeFansOutBelowTheDotAndBranchPointConverges() {
        // m ──┬── f (feature)
        //     └── b (main)
        //          └── a
        let rows = layoutCommitGraph([
            node("m", parents: ["b", "f"]),
            node("f", parents: ["a"]),
            node("b", parents: ["a"]),
            node("a", parents: [])
        ])

        // The merge keeps lane 0 for its first parent and opens lane 1 for the second.
        let merge = rows[0]
        XCTAssertEqual(merge.lane, 0)
        XCTAssertEqual(merge.edges.count, 1)
        XCTAssertEqual(merge.edges[0].kind, .diverge)
        XCTAssertEqual(merge.edges[0].fromLane, 0)
        XCTAssertEqual(merge.edges[0].toLane, 1)
        XCTAssertEqual(merge.laneCount, 2)

        // `f` sits in the lane the merge opened; `b` stays on the mainline.
        XCTAssertEqual(rows[1].commit.id, "f")
        XCTAssertEqual(rows[1].lane, 1)
        XCTAssertEqual(rows[2].commit.id, "b")
        XCTAssertEqual(rows[2].lane, 0)

        // Lanes keep distinct colours, and `f`'s row shows lane 0 passing straight through.
        XCTAssertNotEqual(rows[1].colorIndex, rows[2].colorIndex)
        XCTAssertEqual(rows[1].edges.map(\.kind), [.passThrough])
        XCTAssertEqual(rows[1].edges[0].fromLane, 0)
        XCTAssertEqual(rows[1].edges[0].toLane, 0)

        // `a` is where the branch was cut: both children converge into it.
        let base = rows[3]
        XCTAssertEqual(base.commit.id, "a")
        XCTAssertEqual(base.lane, 0)
        XCTAssertEqual(base.edges.map(\.kind), [.converge])
        XCTAssertEqual(base.edges[0].fromLane, 1)
        XCTAssertEqual(base.edges[0].toLane, 0)
        XCTAssertFalse(base.hasParentBelow)
    }

    func testOctopusMergeOpensALaneForEveryExtraParent() {
        let rows = layoutCommitGraph([
            node("m", parents: ["a", "b", "c"]),
            node("a", parents: []),
            node("b", parents: []),
            node("c", parents: [])
        ])

        let merge = rows[0]
        XCTAssertEqual(merge.edges.filter { $0.kind == .diverge }.map(\.toLane), [1, 2])
        XCTAssertEqual(merge.laneCount, 3)
        XCTAssertEqual(rows.map(\.lane), [0, 0, 1, 2])
    }

    func testLanesAreReusedOnceTheyAreFree() {
        // The feature lane closes at `a`, so the unrelated root `z` takes it back.
        let rows = layoutCommitGraph([
            node("m", parents: ["b", "f"]),
            node("f", parents: ["a"]),
            node("b", parents: ["a"]),
            node("a", parents: []),
            node("z", parents: [])
        ])

        XCTAssertEqual(rows[4].commit.id, "z")
        XCTAssertEqual(rows[4].lane, 0)
        // Reused lanes get a fresh colour so the new history is not mistaken for the old.
        XCTAssertNotEqual(rows[4].colorIndex, rows[3].colorIndex)
    }

    func testParentOutsideTheFetchedWindowRunsOffTheBottom() {
        // `commitGraph` defaults to limit: 120, so the oldest row's parent is often missing.
        let rows = layoutCommitGraph([
            node("b", parents: ["a"]),
            node("a", parents: ["missing"])
        ])

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[1].hasParentBelow, "the lane should keep running past the window")
        XCTAssertEqual(rows[1].laneCount, 1)
    }

    func testOrphanRootsGetTheirOwnLane() {
        let rows = layoutCommitGraph([
            node("b", parents: ["a"]),
            node("a", parents: []),
            node("orphan", parents: [])
        ])

        XCTAssertEqual(rows[2].commit.id, "orphan")
        XCTAssertFalse(rows[2].hasChildAbove)
        XCTAssertFalse(rows[2].hasParentBelow)
        XCTAssertTrue(rows[2].edges.isEmpty)
    }

    func testEmptyHistoryProducesNoRows() {
        XCTAssertTrue(layoutCommitGraph([]).isEmpty)
    }

    private func node(_ id: String, parents: [String]) -> GitCommitNode {
        GitCommitNode(
            id: id,
            shortID: String(id.prefix(7)),
            parentIDs: parents,
            decorations: [],
            author: "GitBud Test",
            authorDate: Date(timeIntervalSince1970: 0),
            subject: "commit \(id)",
            body: ""
        )
    }
}
