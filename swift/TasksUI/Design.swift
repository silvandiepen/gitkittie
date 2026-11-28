import GitKanbanKit
import GitKittieKit
import SwiftUI

// The small pieces the board, the task panel and the sidebar share.

/// A priority as a small filled badge: `P0` on a tint of its colour.
struct PriorityBadge: View {
    let id: String
    let priorities: [Priority]
    var large = false

    var body: some View {
        let color = PriorityPalette.color(id, priorities) ?? .gray
        Text(id)
            .font((large ? Font.callout : Font.caption).weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, large ? 9 : 6).padding(.vertical, large ? 4 : 2)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: large ? 7 : 5))
            .accessibilityLabel("Priority \(id)")
    }
}

/// A count in the sidebar: grey for a plain number, coloured when it wants attention.
struct CountBadge: View {
    let count: Int
    var color: Color?

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(color == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Theme.stroke), in: Capsule())
    }
}

/// A label on a task. The colour comes from the label's own text, so the same label has
/// the same colour everywhere.
struct LabelChip: View {
    let text: String
    var color: Color?

    static func color(for text: String) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green, .mint]
        let sum = text.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }
        return palette[sum % palette.count]
    }

    var body: some View {
        let tint = color ?? Self.color(for: text)
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
    }
}

/// When a task is due, red once the day has passed.
struct DueLabel: View {
    let due: String
    var done = false

    var body: some View {
        let late = !done && (CardDates.date(due).map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false)
        HStack(spacing: 4) {
            Image(systemName: "calendar")
            Text(CardDates.short(due) ?? due)
        }
        .font(.caption)
        .foregroundStyle(late ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .accessibilityLabel("Due \(CardDates.short(due, year: true) ?? due)\(late ? ", overdue" : "")")
    }
}

/// The line under a task's title on the board: priority, due date, activity, assignee.
struct TaskMetaLine: View {
    let card: Card
    let priorities: [Priority]
    var done = false

    var body: some View {
        let activity = CardActivity.count(in: card.body)
        HStack(spacing: 10) {
            if let priority = card.fields.priority { PriorityBadge(id: priority, priorities: priorities) }
            if let due = card.fields.due { DueLabel(due: due, done: done) }
            if activity > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left")
                    Text("\(activity)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(activity) activity entr\(activity == 1 ? "y" : "ies")")
            }
            if let assignee = card.fields.assignee {
                HStack(spacing: 3) {
                    Image(systemName: "at")
                    Text(assignee).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A person as a circle with their initial.
struct Avatar: View {
    let name: String?
    var size: CGFloat = 24

    var body: some View {
        let text = name?.trimmingCharacters(in: .whitespaces) ?? ""
        ZStack {
            Circle().fill(text.isEmpty ? Color.secondary.opacity(0.3) : LabelChip.color(for: text).opacity(0.3))
            if let first = text.first { Text(String(first).uppercased()).font(.system(size: size * 0.45, weight: .semibold)) }
            else { Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Simple flow layout for chips that wraps to next line.
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = max(totalHeight, y + rowHeight)
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
