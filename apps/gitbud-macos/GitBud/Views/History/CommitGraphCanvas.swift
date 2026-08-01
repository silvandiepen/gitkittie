import GitBudCore
import GitKit
import SwiftUI

/// Draws one row's worth of the commit graph.
///
/// Each row paints only its own band, which is what lets the list stay lazy: there is no
/// scroll-offset maths and no giant canvas behind the rows. `layoutCommitGraph` has
/// already decided which lines cross this row and where they start and end.
struct CommitGraphCell: View {
    let row: GitGraphRow
    let laneCount: Int
    let isSelected: Bool

    static let laneWidth: CGFloat = 16
    static let rowHeight: CGFloat = 52

    private static let palette: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo
    ]

    static func color(_ index: Int) -> Color {
        palette[index % palette.count]
    }

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            let dotColor = Self.color(row.colorIndex)

            for edge in row.edges {
                let path = path(for: edge, height: size.height)
                context.stroke(
                    path,
                    with: .color(Self.color(edge.colorIndex).opacity(0.85)),
                    lineWidth: 2
                )
            }

            // The commit's own vertical, split around the dot.
            if row.hasChildAbove {
                var up = Path()
                up.move(to: CGPoint(x: x(row.lane), y: 0))
                up.addLine(to: CGPoint(x: x(row.lane), y: mid))
                context.stroke(up, with: .color(dotColor.opacity(0.85)), lineWidth: 2)
            }
            if row.hasParentBelow {
                var down = Path()
                down.move(to: CGPoint(x: x(row.lane), y: mid))
                down.addLine(to: CGPoint(x: x(row.lane), y: size.height))
                context.stroke(down, with: .color(dotColor.opacity(0.85)), lineWidth: 2)
            }

            // The dot. Merges get a ring so they read differently at a glance.
            let radius: CGFloat = row.commit.parentIDs.count > 1 ? 6 : 5
            let dot = Path(
                ellipseIn: CGRect(
                    x: x(row.lane) - radius,
                    y: mid - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            context.fill(dot, with: .color(row.commit.parentIDs.count > 1 ? GitBudTheme.panel : dotColor))
            context.stroke(dot, with: .color(dotColor), lineWidth: row.commit.parentIDs.count > 1 ? 2.5 : 1)

            if isSelected {
                let halo = Path(
                    ellipseIn: CGRect(
                        x: x(row.lane) - radius - 3.5,
                        y: mid - radius - 3.5,
                        width: (radius + 3.5) * 2,
                        height: (radius + 3.5) * 2
                    )
                )
                context.stroke(halo, with: .color(.white.opacity(0.75)), lineWidth: 1.5)
            }
        }
        .frame(width: CGFloat(max(laneCount, 1)) * Self.laneWidth)
    }

    private func x(_ lane: Int) -> CGFloat {
        CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2
    }

    private func path(for edge: GitGraphEdge, height: CGFloat) -> Path {
        let mid = height / 2
        var path = Path()

        switch edge.kind {
        case .passThrough:
            path.move(to: CGPoint(x: x(edge.fromLane), y: 0))
            path.addLine(to: CGPoint(x: x(edge.fromLane), y: height))

        case .converge:
            // A child's lane coming down and bending into this commit's dot.
            path.move(to: CGPoint(x: x(edge.fromLane), y: 0))
            path.addCurve(
                to: CGPoint(x: x(edge.toLane), y: mid),
                control1: CGPoint(x: x(edge.fromLane), y: mid * 0.6),
                control2: CGPoint(x: x(edge.toLane), y: mid * 0.6)
            )

        case .diverge:
            // An extra parent leaving the dot on its way to its own lane.
            path.move(to: CGPoint(x: x(edge.fromLane), y: mid))
            path.addCurve(
                to: CGPoint(x: x(edge.toLane), y: height),
                control1: CGPoint(x: x(edge.fromLane), y: mid + mid * 0.4),
                control2: CGPoint(x: x(edge.toLane), y: mid + mid * 0.4)
            )
        }

        return path
    }
}
