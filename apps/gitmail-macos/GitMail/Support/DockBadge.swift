import AppKit

/// The Dock badge: unread mail in Focused, nothing else (GKM-018).
enum DockBadge {
    @MainActor
    static func show(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
