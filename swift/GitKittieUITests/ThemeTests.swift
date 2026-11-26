import SwiftUI
import XCTest
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#else
import UIKit
#endif

/// The shared theme under Increase Contrast (GKM-063, MAIL-112): the contrast every colour
/// reaches, and that the colours the apps draw with resolve to the high-contrast values.
/// Compiled into the Mail test bundles on the Mac and on iOS together with
/// `swift/GitKittieUI/Theme.swift`.
final class ThemeTests: XCTestCase {
    private let dark = Theme.Appearance(isDark: true, isHighContrast: false)
    private let darkHigh = Theme.Appearance(isDark: true, isHighContrast: true)
    private let light = Theme.Appearance(isDark: false, isHighContrast: false)
    private let lightHigh = Theme.Appearance(isDark: false, isHighContrast: true)

    // MARK: Contrast

    func testStrokesReachThreeToOneOnEverySurfaceAtHighContrast() {
        for appearance in [darkHigh, lightHigh] {
            let stroke = Theme.Swatch.stroke.hex(for: appearance)
            for surface in Theme.Swatch.surfaces {
                let ratio = contrast(stroke, surface.hex(for: appearance))
                XCTAssertGreaterThanOrEqual(ratio, 3, "stroke on \(hexString(surface.hex(for: appearance))), \(appearance): \(ratio)")
            }
        }
    }

    func testHighContrastStrokesAreStrongerThanStandard() {
        for (standard, high) in [(dark, darkHigh), (light, lightHigh)] {
            for surface in Theme.Swatch.surfaces {
                XCTAssertGreaterThan(
                    contrast(Theme.Swatch.stroke.hex(for: high), surface.hex(for: high)),
                    contrast(Theme.Swatch.stroke.hex(for: standard), surface.hex(for: standard)))
            }
        }
    }

    func testAccentTextReachesSevenToOneOnTheNavyAndFourAndAHalfOnSystemRows() {
        let text = Theme.Swatch.accentText.hex(for: darkHigh)
        for surface in Theme.Swatch.surfaces {
            XCTAssertGreaterThanOrEqual(contrast(text, surface.hex(for: darkHigh)), 7)
        }
        // The raised rows of a dark form or sheet (MAIL-089); iOS draws these, not the theme.
        for row: UInt32 in [0x2C2C2E, 0x3A3A3C] {
            XCTAssertGreaterThanOrEqual(contrast(text, row), 4.5)
        }
        XCTAssertGreaterThan(contrast(text, 0x2C2C2E), contrast(Theme.Swatch.accentText.hex(for: dark), 0x2C2C2E))
    }

    func testAccentsAreTextOnLightSurfacesAtHighContrast() {
        for swatch in [Theme.Swatch.accent, .accentText] {
            for surface in Theme.Swatch.surfaces {
                XCTAssertGreaterThanOrEqual(contrast(swatch.hex(for: lightHigh), surface.hex(for: lightHigh)), 4.5)
            }
        }
    }

    func testAccentStaysTextOnTheNavyAtHighContrast() {
        for surface in Theme.Swatch.surfaces {
            XCTAssertGreaterThanOrEqual(contrast(Theme.Swatch.accent.hex(for: darkHigh), surface.hex(for: darkHigh)), 4.5)
        }
    }

    func testWhiteOnAccentFillReachesSevenToOneAtHighContrast() {
        for appearance in [darkHigh, lightHigh] {
            XCTAssertGreaterThanOrEqual(contrast(0xFFFFFF, Theme.Swatch.accentFill.hex(for: appearance)), 7)
        }
        XCTAssertGreaterThanOrEqual(contrast(0xFFFFFF, Theme.Swatch.accentFill.hex(for: dark)), 4.5)
    }

    func testDarkSurfacesStepFurtherApartAtHighContrast() {
        let window = Theme.Swatch.window, card = Theme.Swatch.card
        XCTAssertGreaterThan(
            contrast(card.hex(for: darkHigh), window.hex(for: darkHigh)),
            contrast(card.hex(for: dark), window.hex(for: dark)))
    }

    // MARK: Resolution

    /// The colours the views draw with, resolved the way the system resolves them.
    func testColoursResolveToTheirHighContrastValues() {
        let swatches: [Theme.Swatch] = [.window, .sidebar, .panel, .card, .stroke, .accent, .accentText, .accentFill]
        for swatch in swatches {
            for appearance in [dark, darkHigh, light, lightHigh] {
                XCTAssertEqual(resolved(swatch, appearance), swatch.hex(for: appearance), "\(swatch) for \(appearance)")
            }
        }
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// `NSAppearance(named:)` gives the plain appearance for a high-contrast name while the Mac's
    /// Increase Contrast is off, so the setting is what the tests vary.
    func testMacAppearancesMapToTheTheme() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertEqual(Theme.Appearance(aqua, systemIncreasesContrast: false), light)
        XCTAssertEqual(Theme.Appearance(darkAqua, systemIncreasesContrast: false), dark)
        XCTAssertEqual(Theme.Appearance(aqua, systemIncreasesContrast: true), lightHigh)
        // A window pinned to dark (`preferredColorScheme(.dark)`) still follows the setting.
        XCTAssertEqual(Theme.Appearance(darkAqua, systemIncreasesContrast: true), darkHigh)
    }

    func testTheColoursTheAppsUseFollowTheSystemSetting() {
        let setting = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        for appearance in [dark, light] {
            let effective = Theme.Appearance(isDark: appearance.isDark, isHighContrast: setting)
            XCTAssertEqual(draw(Theme.Swatch.stroke.nsColor, appearance), Theme.Swatch.stroke.hex(for: effective))
        }
    }

    private func resolved(_ swatch: Theme.Swatch, _ appearance: Theme.Appearance) -> UInt32 {
        let isHighContrast = appearance.isHighContrast
        return draw(swatch.nsColor(systemIncreasesContrast: { isHighContrast }), appearance)
    }

    /// The colour as AppKit draws it in a plain light or dark appearance.
    private func draw(_ color: NSColor, _ appearance: Theme.Appearance) -> UInt32 {
        var drawn: NSColor?
        NSAppearance(named: appearance.isDark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            drawn = color.usingColorSpace(.sRGB)
        }
        return hex(red: drawn!.redComponent, green: drawn!.greenComponent, blue: drawn!.blueComponent)
    }
    #else
    func testTraitsMapToTheTheme() {
        XCTAssertEqual(Theme.Appearance(traits(dark: true, high: true)), darkHigh)
        XCTAssertEqual(Theme.Appearance(traits(dark: true, high: false)), dark)
        XCTAssertEqual(Theme.Appearance(traits(dark: false, high: true)), lightHigh)
        XCTAssertEqual(Theme.Appearance(traits(dark: false, high: false)), light)
    }

    private func traits(dark: Bool, high: Bool) -> UITraitCollection {
        UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.accessibilityContrast = high ? .high : .normal
        }
    }

    private func resolved(_ swatch: Theme.Swatch, _ appearance: Theme.Appearance) -> UInt32 {
        let color = swatch.uiColor.resolvedColor(with: traits(dark: appearance.isDark, high: appearance.isHighContrast))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return hex(red: red, green: green, blue: blue)
    }
    #endif

    // MARK: Helpers

    private func hex(red: CGFloat, green: CGFloat, blue: CGFloat) -> UInt32 {
        func byte(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    private func hexString(_ value: UInt32) -> String { String(format: "#%06X", value) }

    /// WCAG 2 contrast ratio of two sRGB colours.
    private func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let value = Double((hex >> shift) & 0xFF) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
