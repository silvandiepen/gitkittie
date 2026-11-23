import SwiftUI

// On its own, outside Design.swift, so the share and action extensions can compile it
// without the rest of TasksUI: their board panel shows boards in their own colours.

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
