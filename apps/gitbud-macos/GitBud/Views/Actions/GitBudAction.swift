import AppKit
import GitBudCore
import GitKit
import SwiftUI

/// One verb the user can invoke on something.
///
/// Actions are declared once in `GitBudActions` and rendered three ways — as a context
/// menu on the item, as a toolbar in the detail pane, and as rows in the ⌘K palette.
/// Adding a verb means one entry here, not three call sites.
struct GitBudAction: Identifiable {
    /// What the action needs from the user before it runs.
    enum Interaction {
        /// Runs straight away.
        case immediate
        /// Asks for a value first (a branch name, a commit message).
        case input(title: String, placeholder: String, defaultValue: String, verb: String)
        /// Asks for a yes.
        case confirm(title: String, message: String, verb: String)
        /// Asks the user to type an exact phrase. For things that rewrite published history.
        case confirmTyped(title: String, message: String, phrase: String, verb: String)
    }

    let id: String
    let title: String
    let icon: String
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    /// Why the action is unavailable, shown when it is disabled.
    var disabledReason: String?
    var interaction: Interaction = .immediate
    /// Receives the entered text for `.input`, or an empty string otherwise.
    let perform: @MainActor (String) -> Void

    var needsSheet: Bool {
        if case .immediate = interaction { return false }
        return true
    }
}

extension GitBudAction {
    /// A disabled copy carrying the reason, so menus can explain themselves instead of
    /// just greying out.
    func disabled(when condition: Bool, reason: String) -> GitBudAction {
        guard condition else { return self }
        var copy = self
        copy.isEnabled = false
        copy.disabledReason = reason
        return copy
    }
}

/// Copies text to the pasteboard. UI-only, so it belongs here rather than in AppModel.
@MainActor
func gitBudCopyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
