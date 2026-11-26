import Foundation

/// The Mac menu bar's commands that have a keyboard shortcut (GITKITTIE-099).
///
/// SwiftUI reads a menu item's `.disabled(…)`, its title and the values its action captures when
/// it syncs that menu: at launch, and again each time the person opens the menu. It does not
/// sync when the model changes. A shortcut uses the last sync, so Refresh (⌘R) and the views
/// (⌘1…⌘4), disabled at launch because no repository was open yet, kept dead shortcuts after a
/// repository was opened, until the View menu was opened. These items therefore stay enabled and
/// ask the model when they run; when they can't act, the reason goes to the alert.
public enum GitBudMenuCommand: Equatable {
    /// View ▸ Refresh (⌘R).
    case refresh
    /// View ▸ History (⌘1), Changes (⌘2), Branches (⌘3), Pull Requests (⌘4).
    case showWorkspace(GitBudWorkspaceMode)
}

extension AppModel {
    /// What the alert says when a command needs a repository and none is open.
    public static let noRepositoryReason = "Open a repository first with File ▸ Open Repository… (⌘O)."

    /// Why `command` can't run now, in words for the alert; nil when it can.
    public func unavailableReason(_ command: GitBudMenuCommand) -> String? {
        guard repositoryURL != nil else { return Self.noRepositoryReason }
        switch command {
        case .refresh:
            return isLoading ? "The repository is still loading. Try again in a moment." : nil
        case .showWorkspace:
            return nil
        }
    }

    /// For a menu command as it runs: true when it can; otherwise its reason goes to the alert
    /// (`errorMessage`) and it returns false.
    public func canRun(_ command: GitBudMenuCommand) -> Bool {
        guard let reason = unavailableReason(command) else { return true }
        errorMessage = reason
        return false
    }
}
