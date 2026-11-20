import GitKanbanKit
import GitKittieKit
import SwiftUI

extension Color {
    /// The system colour for a board's `color:` name; the accent colour for none or an unknown one.
    init(boardColor name: String?) {
        switch name {
        case "blue": self = .blue
        case "indigo": self = .indigo
        case "purple": self = .purple
        case "pink": self = .pink
        case "red": self = .red
        case "orange": self = .orange
        case "yellow": self = .yellow
        case "green": self = .green
        case "mint": self = .mint
        case "teal": self = .teal
        case "brown": self = .brown
        case "gray": self = .gray
        default: self = .accentColor
        }
    }
}

/// A board's own settings: display name, icon and colour. Saved into the board's README in
/// git, so every device and everyone on the repo sees the same. Lanes, priorities and
/// members are in the full project settings, one button away.
struct BoardSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: AddedRepo
    let board: SelectedBoard

    @State private var name = ""
    @State private var icon: String?
    @State private var color: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { icon != board.icon || color != board.color || (trimmedName != board.name && !trimmedName.isEmpty) }
    private var isOpen: Bool { model.activeRepo?.id == repo.id && model.activeBoardFolder == board.folder }

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon ?? BoardAppearance.defaultIcon)
                    .font(.title2)
                    .foregroundStyle(Color(boardColor: color))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Board Settings").font(.headline)
                    Text(board.folder.isEmpty ? repo.displayName : "\(repo.displayName) · \(board.folder)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline).foregroundStyle(.secondary)
                TextField(board.name, text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("How the board is called in the sidebar and its title. The folder keeps its name.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.subheadline).foregroundStyle(.secondary)
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
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(BoardAppearance.icons, id: \.self) { name in
                        Button { icon = name == BoardAppearance.defaultIcon ? nil : name } label: {
                            Image(systemName: name)
                                .frame(width: 34, height: 30)
                                .foregroundStyle((icon ?? BoardAppearance.defaultIcon) == name ? Color(boardColor: color) : .secondary)
                                .background(
                                    (icon ?? BoardAppearance.defaultIcon) == name ? Color.primary.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits((icon ?? BoardAppearance.defaultIcon) == name ? .isSelected : [])
                    }
                }
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lanes, priorities, members, types and epics")
                    Text("Opens the board and its full settings.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("More Settings…") {
                    Task {
                        if !isOpen { await model.openBoard(repo, folder: board.folder) }
                        model.wantsProjectSettings = true
                    }
                    dismiss()
                }
                .disabled(changed)
                .help(changed ? "Save or reset your changes here first" : "")
            }

            Text("Saved in the board's README in the repository, so it is the same everywhere.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Reset Icon & Color") { icon = nil; color = nil }
                    .disabled(icon == nil && color == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let (name, icon, color) = (trimmedName, icon, color)
                    Task { await model.saveBoardSettings(board, in: repo, name: name, icon: icon, color: color) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!changed)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { name = board.name; icon = board.icon; color = board.color }
    }
}
