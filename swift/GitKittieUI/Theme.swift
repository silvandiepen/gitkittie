import SwiftUI

/// The app's own surfaces: solid, dark navy, the same on the Mac and the iPhone.
///
/// The system's window and sidebar backgrounds are translucent and take a tint from the
/// desktop picture behind them. These are opaque, so the app looks the same on every desk.
enum Theme {
    /// Behind everything: the board, a page, a list.
    static let window = dynamic(light: 0xF3F5F9, dark: 0x0B101B)
    /// The sidebar, a step darker than the window.
    static let sidebar = dynamic(light: 0xE9ECF2, dark: 0x080C15)
    /// A raised area on the window: a lane's header, the task panel, a group of rows.
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x111827)
    /// A task card, a step lighter than a panel.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x161F31)
    /// The hairline around panels and cards.
    static let stroke = dynamic(light: 0xD9DEE8, dark: 0x232D42)
    /// The one accent: selection, links, the primary button.
    static let accent = Color(red: 0x4F / 255, green: 0x8C / 255, blue: 1)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

extension View {
    /// A list on the app's own background, in place of the system's grey.
    func themedList() -> some View {
        scrollContentBackground(.hidden).background(Theme.window.ignoresSafeArea())
    }
}
