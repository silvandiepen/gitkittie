import GitKanbanKit
import GitKittieKit
import SwiftUI

/// The colour and icon of a board: twelve colours, and every SF Symbol with a filter.
/// Saved into the board's README in git, so every device shows the same.
struct BoardAppearancePicker: View {
    @Binding var icon: String?
    @Binding var color: String?
    @State private var iconFilter = ""

    private var shownIcons: [SymbolCatalog.Symbol] { SymbolCatalog.system.matching(iconFilter) }
    private let columns = [GridItem(.adaptive(minimum: 34), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(BoardAppearance.colors, id: \.self) { name in
                    Button { color = color == name ? nil : name } label: {
                        Circle()
                            .fill(Color(boardColor: name))
                            .frame(width: 22, height: 22)
                            .overlay { if color == name { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) } }
                    }
                    .buttonStyle(.plain)
                    .help(name.capitalized)
                    .accessibilityLabel(name.capitalized)
                    .accessibilityAddTraits(color == name ? .isSelected : [])
                }
            }
            HStack {
                TextField("Filter icons", text: $iconFilter, prompt: Text("Filter icons: folder, game, chart…"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .accessibilityIdentifier("boardIconFilter")
                Text(iconFilter.isEmpty ? "\(shownIcons.count) icons" : "\(shownIcons.count) found")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(shownIcons) { symbol in
                        let name = symbol.name
                        let isSelected = (icon ?? BoardAppearance.defaultIcon) == name
                        Button { icon = name == BoardAppearance.defaultIcon ? nil : name } label: {
                            Image(systemName: name)
                                .frame(width: 34, height: 30)
                                .foregroundStyle(isSelected ? Color(boardColor: color) : .secondary)
                                .background(isSelected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(6)
            }
            .frame(height: 220)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if shownIcons.isEmpty { Text("No icon matches “\(iconFilter)”").font(.callout).foregroundStyle(.secondary) }
            }
            Button("Reset Icon & Color") { icon = nil; color = nil }
                .disabled(icon == nil && color == nil)
        }
    }
}
