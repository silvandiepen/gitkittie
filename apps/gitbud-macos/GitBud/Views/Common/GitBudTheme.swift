import AppKit
import GitBudCore
import GitKittieKit
import SwiftUI

// Visual primitives shared by every GitKittie Bud surface. The colours are the family's
// (`swift/GitKittieUI/Theme.swift`, the same file Tasks and Folder use); this file only
// names what Bud draws with them.

enum GitBudTheme {
    /// Behind everything.
    static let background = Theme.window
    /// The sidebar, a step darker than the window.
    static let sidebar = Theme.sidebar
    /// A raised area: a sheet, a header strip, a group of rows.
    static let panel = Theme.panel
    /// A row or card on a panel, a step lighter again.
    static let card = Theme.card
    /// The one hairline.
    static let stroke = Theme.stroke
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
}

extension View {
    /// A group on the window: a step lighter, one hairline, no shadow.
    func panelCard() -> some View {
        padding(12)
            .background(GitBudTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(GitBudTheme.stroke)
            }
    }

    /// A row in a list. Selected and marked rows are told apart by a tinted fill and nothing
    /// else — never an outline or an edge bar.
    func gitBudPanelRow(
        isSelected: Bool = false,
        isMarked: Bool = false,
        tint: Color = .accentColor,
        markedColor: Color = .orange,
        cornerRadius: CGFloat = 8,
        baseOpacity: Double = 0.055
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fill: Color
        if isSelected {
            fill = tint.opacity(0.20)
        } else if isMarked {
            fill = markedColor.opacity(0.14)
        } else {
            fill = Color.primary.opacity(baseOpacity)
        }
        return background(fill, in: shape)
    }
}

/// Gives the window the family's opaque background in place of the system's translucent
/// one, and draws the app in dark, as Tasks does, unless the system is asked otherwise.
struct SolidWindow: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.backgroundColor = NSColor(Theme.window)
            window.isOpaque = true
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// A count in the sidebar: grey for a plain number, coloured when it wants attention.
struct CountBadge: View {
    let count: Int
    var color: Color?

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(color == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.quaternary), in: Capsule())
    }
}

struct EmptyPanel: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(GitBudTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

func panelTitle(_ title: String, icon: String) -> some View {
    HStack(spacing: 9) {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 26, height: 26)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        Text(title)
            .font(.headline.weight(.semibold))
        Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.top, 14)
}

struct StatusPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct CompactMetric: View {
    let label: String
    let value: Int

    init(_ label: String, _ value: Int) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(GitBudTheme.secondaryText)
            Text("\(value)")
                .font(.caption.monospaced().weight(.bold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(GitBudTheme.card, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline.weight(.semibold))
            Spacer()
        }
    }
}
