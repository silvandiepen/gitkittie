import GitBudCore
import GitKittieKit
import SwiftUI

// Visual primitives shared by every GitBud surface.

enum GitBudTheme {
    static let background = Color(red: 0.075, green: 0.078, blue: 0.085)
    static let panel = Color(red: 0.105, green: 0.110, blue: 0.120)
    static let cardFill = Color.white.opacity(0.064)
    static let cardBorder = Color.white.opacity(0.105)
    static let toolFill = Color.white.opacity(0.080)
    static let toolBorder = Color.white.opacity(0.130)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.58)
}

extension View {
    func panelCard() -> some View {
        padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(GitBudTheme.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(GitBudTheme.cardBorder)
            }
            .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
    }

    func gitBudPanelRow(
        isSelected: Bool = false,
        isMarked: Bool = false,
        tint: Color = .accentColor,
        markedColor: Color = .orange,
        cornerRadius: CGFloat = 8,
        baseOpacity: Double = 0.055
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(isSelected ? tint.opacity(0.22) : Color.white.opacity(baseOpacity), in: shape)
            .overlay {
                shape.strokeBorder(rowBorderColor(isSelected: isSelected, isMarked: isMarked, tint: tint, markedColor: markedColor))
            }
    }

    private func rowBorderColor(isSelected: Bool, isMarked: Bool, tint: Color, markedColor: Color) -> Color {
        if isMarked { return markedColor.opacity(0.72) }
        if isSelected { return tint.opacity(0.50) }
        return Color.white.opacity(0.085)
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
            .frame(width: 26, height: 26)
            .background(GitBudTheme.toolFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(GitBudTheme.toolBorder)
            }
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
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
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
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
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

