import Foundation

// Lane assignment for the commit graph.
//
// Pure value-in/value-out: it takes the newest-first `[GitCommitNode]` that
// `GitHistory.commitGraph` already returns and works out where each commit's dot sits
// and which lines cross each row. No UI, no process launching, no I/O — so it is
// testable without a repository and reusable by any renderer.
//
// Lanes are reused but never re-indexed: once a lane frees up a later commit may take
// it, but occupied lanes keep their column for as long as they live. That keeps every
// pass-through line perfectly vertical, which is what makes a graph readable.

/// One line segment crossing a single graph row.
///
/// A row is drawn in three bands: top edge → dot → bottom edge. `fromLane` is the
/// position at the top edge, `toLane` the position at the bottom edge.
public struct GitGraphEdge: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// An unrelated lane passing straight through this row. `fromLane == toLane`.
        case passThrough
        /// A child's lane joining this commit's dot. Drawn top edge → dot.
        case converge
        /// An extra parent leaving this commit's dot. Drawn dot → bottom edge.
        case diverge
    }

    public let fromLane: Int
    public let toLane: Int
    public let colorIndex: Int
    public let kind: Kind

    public init(fromLane: Int, toLane: Int, colorIndex: Int, kind: Kind) {
        self.fromLane = fromLane
        self.toLane = toLane
        self.colorIndex = colorIndex
        self.kind = kind
    }
}

/// One commit, placed.
public struct GitGraphRow: Sendable, Identifiable, Equatable {
    public let commit: GitCommitNode
    /// Column the commit's dot sits in.
    public let lane: Int
    /// Stable colour for this commit's lane. Renderers take this modulo their palette size.
    public let colorIndex: Int
    /// Whether a line continues upward out of the dot (this commit has a child on screen).
    public let hasChildAbove: Bool
    /// Whether a line continues downward out of the dot (this commit has a first parent).
    public let hasParentBelow: Bool
    /// Lines crossing this row that are not the dot's own vertical.
    public let edges: [GitGraphEdge]
    /// Columns in use on this row, so a renderer can size the rail.
    public let laneCount: Int

    public var id: String { commit.id }

    public init(
        commit: GitCommitNode,
        lane: Int,
        colorIndex: Int,
        hasChildAbove: Bool,
        hasParentBelow: Bool,
        edges: [GitGraphEdge],
        laneCount: Int
    ) {
        self.commit = commit
        self.lane = lane
        self.colorIndex = colorIndex
        self.hasChildAbove = hasChildAbove
        self.hasParentBelow = hasParentBelow
        self.edges = edges
        self.laneCount = laneCount
    }
}

/// Places every commit in a lane and works out the lines crossing each row.
///
/// `commits` must be newest-first, the order `GitHistory.commitGraph` returns. Commits whose
/// parents fall outside the fetched window are handled: their lane simply runs off the bottom
/// of the graph rather than terminating.
public func layoutCommitGraph(_ commits: [GitCommitNode]) -> [GitGraphRow] {
    var lanes: [String?] = []       // lanes[i] == the commit id lane i is waiting for
    var laneColors: [Int] = []      // lanes[i]'s colour, stable while the lane stays occupied
    var nextColor = 0
    var rows: [GitGraphRow] = []
    rows.reserveCapacity(commits.count)

    func occupiedWidth() -> Int {
        (lanes.lastIndex { $0 != nil }).map { $0 + 1 } ?? 0
    }

    func allocateLane() -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) {
            laneColors[free] = nextColor
            nextColor += 1
            return free
        }
        lanes.append(nil)
        laneColors.append(nextColor)
        nextColor += 1
        return lanes.count - 1
    }

    for commit in commits {
        let widthAbove = occupiedWidth()

        // Every lane waiting for this commit belongs to one of its children.
        let expecting = lanes.indices.filter { lanes[$0] == commit.id }
        let hasChildAbove = !expecting.isEmpty
        let lane = expecting.first ?? allocateLane()
        let colorIndex = laneColors[lane]

        var edges: [GitGraphEdge] = []

        // Extra children converge into the dot and give their lanes back.
        for other in expecting.dropFirst() {
            edges.append(
                GitGraphEdge(fromLane: other, toLane: lane, colorIndex: laneColors[other], kind: .converge)
            )
            lanes[other] = nil
        }

        // Everything else carries straight on past this row.
        for index in lanes.indices where index != lane && lanes[index] != nil {
            edges.append(
                GitGraphEdge(fromLane: index, toLane: index, colorIndex: laneColors[index], kind: .passThrough)
            )
        }

        // The first parent inherits the lane — and therefore the colour — so a branch
        // keeps one column for its whole life.
        let parents = commit.parentIDs
        lanes[lane] = parents.first

        // Additional parents (a merge) fan out below the dot.
        for parent in parents.dropFirst() {
            if let existing = lanes.firstIndex(where: { $0 == parent }), existing != lane {
                edges.append(
                    GitGraphEdge(fromLane: lane, toLane: existing, colorIndex: laneColors[existing], kind: .diverge)
                )
            } else {
                let target = allocateLane()
                lanes[target] = parent
                edges.append(
                    GitGraphEdge(fromLane: lane, toLane: target, colorIndex: laneColors[target], kind: .diverge)
                )
            }
        }

        rows.append(
            GitGraphRow(
                commit: commit,
                lane: lane,
                colorIndex: colorIndex,
                hasChildAbove: hasChildAbove,
                hasParentBelow: parents.first != nil,
                edges: edges,
                laneCount: max(lane + 1, widthAbove, occupiedWidth())
            )
        )
    }

    return rows
}
