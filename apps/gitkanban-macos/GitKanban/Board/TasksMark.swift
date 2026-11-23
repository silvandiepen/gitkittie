import SwiftUI

/// The Tasks mark (two stacked cards of lines), drawn rather than loaded so it can move:
/// the last line of the left card keeps travelling to the right card, a task changing
/// lanes. Same geometry as the `GitKanbanLines` asset (512 × 470). Still when Reduce
/// Motion is on.
struct TasksMark: View {
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let canvas = CGSize(width: 512, height: 470)
    private static let cycle: TimeInterval = 2.6

    var body: some View {
        TimelineView(.animation(paused: !animated || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = animated && !reduceMotion ? time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle : nil
            Canvas { context, size in
                let scale = min(size.width / Self.canvas.width, size.height / Self.canvas.height)
                context.translateBy(x: (size.width - Self.canvas.width * scale) / 2,
                                    y: (size.height - Self.canvas.height * scale) / 2)
                context.scaleBy(x: scale, y: scale)
                draw(in: &context, phase: phase)
            }
        }
        .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, phase: Double?) {
        let ink = GraphicsContext.Shading.foreground
        let stroke = StrokeStyle(lineWidth: 14, lineJoin: .round)
        for x in [15.0, 262.0] {
            let front = Path(roundedRect: CGRect(x: x, y: 10, width: 195, height: 400), cornerRadius: 36)
            let back = Path(roundedRect: CGRect(x: x + 40, y: 48, width: 195, height: 400), cornerRadius: 36)
            // The card behind shows only where the front card doesn't cover it.
            var behind = context
            behind.clip(to: front, options: .inverse)
            behind.stroke(back, with: ink, style: stroke)
            context.stroke(front, with: ink, style: stroke)
        }

        func line(x: Double, y: Double, opacity: Double = 1) {
            var layer = context
            layer.opacity = opacity
            layer.fill(Path(roundedRect: CGRect(x: x, y: y, width: 120, height: 34), cornerRadius: 17), with: ink)
        }
        let left = 52.0, right = 298.0, rows = [93.0, 173.0, 257.0]
        line(x: left, y: rows[0]); line(x: left, y: rows[1])
        line(x: right, y: rows[0]); line(x: right, y: rows[1])

        // The travelling line: appears on the left, slides across, rests, fades out.
        guard let phase else { return line(x: left, y: rows[2]) }
        switch phase {
        case ..<0.15:
            line(x: left, y: rows[2], opacity: phase / 0.15)
        case ..<0.55:
            let t = (phase - 0.15) / 0.4
            let eased = t * t * (3 - 2 * t)
            line(x: left + (right - left) * eased, y: rows[2] - sin(eased * .pi) * 22)
        case ..<0.85:
            line(x: right, y: rows[2])
        default:
            line(x: right, y: rows[2], opacity: 1 - (phase - 0.85) / 0.15)
        }
    }
}

/// "Tasks" with the mark above it and a small "by GitKittie" underneath.
struct TasksWordmark: View {
    var markSize: CGFloat = 80
    var animated = true

    var body: some View {
        VStack(spacing: 14) {
            TasksMark(animated: animated)
                .frame(width: markSize, height: markSize)
                .foregroundStyle(.tint)
            Text("Tasks").font(.largeTitle.bold())
            HStack(spacing: 5) {
                Text("by")
                Image("GitKittieMark")
                    .resizable().scaledToFit().frame(height: 15)
                Text("GitKittie")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tasks, by GitKittie")
    }
}
