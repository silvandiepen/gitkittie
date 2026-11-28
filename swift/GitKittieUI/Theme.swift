import SwiftUI

/// The app's own surfaces: solid, dark navy, the same on the Mac and the iPhone.
///
/// The system's window and sidebar backgrounds are translucent and take a tint from the
/// desktop picture behind them. These are opaque, so the app looks the same on every desk.
///
/// Every colour has a high-contrast value for Increase Contrast (iOS: `accessibilityContrast`
/// `.high`; macOS: the high-contrast Aqua appearances), so each app follows the setting
/// without a view of its own asking for it (GKM-063).
enum Theme {
    /// Behind everything: the board, a page, a list.
    static let window = Swatch.window.color
    /// The sidebar, a step darker than the window.
    static let sidebar = Swatch.sidebar.color
    /// A raised area on the window: a lane's header, the task panel, a group of rows.
    static let panel = Swatch.panel.color
    /// A task card, a step lighter than a panel.
    static let card = Swatch.card.color
    /// A bar or a control that floats over the content (a bottom bar, a toolbar capsule, a
    /// toast, a badge on a picture), and a row of a grouped list or form: the system draws these
    /// in grey materials and greys (#1C1C1E, #2C2C2E), which read as grey on the navy.
    static let bar = Swatch.bar.color
    /// The hairline around panels and cards.
    static let stroke = Swatch.stroke.color
    /// The one accent: selection, links, the primary button.
    static let accent = Swatch.accent.color
    /// The accent for text and symbols on the raised rows of a dark form or sheet (#2C2C2E,
    /// #3A3A3C), where `accent` is under 4.5:1: 4.6:1 there, 7.8:1 on `window`.
    static let accentText = Swatch.accentText.color
    /// The accent under white text (a prominent button, a swipe action): 5:1, where white on
    /// `accent` is 3.2:1.
    static let accentFill = Swatch.accentFill.color

    /// The appearance a colour is drawn for.
    struct Appearance: Equatable, Sendable {
        var isDark: Bool
        var isHighContrast: Bool

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        /// AppKit vends the high-contrast appearances only while Increase Contrast is on, and an
        /// app that pins its windows to `.darkAqua` (`preferredColorScheme(.dark)`) may get the
        /// plain one back, so the system setting counts as well as the appearance's name.
        init(_ appearance: NSAppearance, systemIncreasesContrast: Bool) {
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
            ])
            isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            isHighContrast = systemIncreasesContrast
                || match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        }
        #else
        init(_ traits: UITraitCollection) {
            isDark = traits.userInterfaceStyle == .dark
            isHighContrast = traits.accessibilityContrast == .high
        }
        #endif

        init(isDark: Bool, isHighContrast: Bool) {
            self.isDark = isDark
            self.isHighContrast = isHighContrast
        }
    }

    /// One colour's sRGB values for light and dark, each at standard and at high contrast.
    ///
    /// High contrast (MAIL-112): strokes reach 3:1 against every surface they sit on, the
    /// surfaces step further apart, `accentText` reaches 7:1 on the navy and white on
    /// `accentFill` 7:1. `accent` stays at the standard value on the navy: it is both the Mac's
    /// tint, under white text in a prominent button, and text on the navy, so lighter would hurt
    /// one and darker the other.
    struct Swatch: Equatable, Sendable {
        let light: UInt32
        let dark: UInt32
        let lightHighContrast: UInt32
        let darkHighContrast: UInt32

        static let window = Swatch(light: 0xF3F5F9, dark: 0x0B101B, lightHighContrast: 0xF3F5F9, darkHighContrast: 0x05080F)
        static let sidebar = Swatch(light: 0xE9ECF2, dark: 0x080C15, lightHighContrast: 0xE6E9F0, darkHighContrast: 0x020408)
        static let panel = Swatch(light: 0xFFFFFF, dark: 0x111827, lightHighContrast: 0xFFFFFF, darkHighContrast: 0x111827)
        static let card = Swatch(light: 0xFFFFFF, dark: 0x161F31, lightHighContrast: 0xFFFFFF, darkHighContrast: 0x182236)
        /// Between a panel and a card, so a bar stands off the window and a card can still sit on it.
        static let bar = Swatch(light: 0xFFFFFF, dark: 0x131C2C, lightHighContrast: 0xFFFFFF, darkHighContrast: 0x141D2E)
        static let stroke = Swatch(light: 0xD9DEE8, dark: 0x232D42, lightHighContrast: 0x6E7A8F, darkHighContrast: 0x6B7A99)
        static let accent = Swatch(light: 0x4F8CFF, dark: 0x4F8CFF, lightHighContrast: 0x1F5BD1, darkHighContrast: 0x4F8CFF)
        static let accentText = Swatch(light: 0x75A5FF, dark: 0x75A5FF, lightHighContrast: 0x1A4FB8, darkHighContrast: 0x9DC0FF)
        static let accentFill = Swatch(light: 0x2B68E0, dark: 0x2B68E0, lightHighContrast: 0x1A4FB8, darkHighContrast: 0x1A4FB8)

        /// The surfaces a stroke or an accent is drawn on.
        static let surfaces: [Swatch] = [.window, .sidebar, .panel, .card, .bar]

        func hex(for appearance: Appearance) -> UInt32 {
            switch (appearance.isDark, appearance.isHighContrast) {
            case (false, false): light
            case (true, false): dark
            case (false, true): lightHighContrast
            case (true, true): darkHighContrast
            }
        }

        /// The colour, resolved for the appearance it is drawn in.
        var color: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            Color(nsColor: nsColor)
            #else
            Color(uiColor: uiColor)
            #endif
        }

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        var nsColor: NSColor {
            nsColor(systemIncreasesContrast: { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast })
        }

        /// The colour, asking `systemIncreasesContrast` for the Increase Contrast setting each time
        /// it is drawn.
        func nsColor(systemIncreasesContrast: @escaping @Sendable () -> Bool) -> NSColor {
            NSColor(name: nil) { appearance in
                NSColor(hex: hex(for: Appearance(appearance, systemIncreasesContrast: systemIncreasesContrast())))
            }
        }
        #else
        var uiColor: UIColor {
            UIColor { traits in UIColor(hex: hex(for: Appearance(traits))) }
        }
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
    /// A list or form on the app's own background, in place of the system's grey.
    func themedList() -> some View {
        scrollContentBackground(.hidden).background(Theme.window.ignoresSafeArea())
    }

    /// Rows of a grouped list or form on the navy `bar` surface, in place of the system's grey
    /// row. Put it on a section, or on a `Group` around a list's sections to reach every row.
    func themedRows() -> some View {
        listRowBackground(Theme.bar)
    }

    /// A bar or control floating over the content, on the navy `bar` surface with the theme's
    /// hairline, in place of the system's grey material.
    func themedBar<S: InsettableShape>(in shape: S) -> some View {
        background(Theme.bar, in: shape).overlay { shape.strokeBorder(Theme.stroke, lineWidth: 1) }
    }
}
