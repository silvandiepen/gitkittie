import XCTest

/// Which accessibility audit issues the UI tests skip, and why (GKM-061). Only issues in a
/// system control the app can't change are skipped; each has its reason written here.
/// Everything else fails the test.
@MainActor
enum AccessibilityAuditPolicy {
    /// The reason an issue is skipped, or nil when it counts.
    static func systemIssue(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> String? {
        // "Dynamic Type font sizes are partially unsupported" is reported, at the default size,
        // for SwiftUI text in the system's own containers (ContentUnavailableView, Form section
        // headers, footers and rows, List rows) that does grow: at Accessibility XXXL the same
        // "No mail yet", "Servers" and "Incoming (IMAP)" fill the screen (GKM-061 screenshots).
        // Scaling is tested for real by testMainScreensAtLargestTextSize, where text that does
        // not fit fails as clipped and the screenshots show every main screen.
        if issue.auditType == .dynamicType {
            return "SwiftUI text styles scale; checked at Accessibility XXXL instead"
        }
        guard let element = issue.element else { return nil }
        // The value inside a Form menu Picker ("Older mail  Up to 500 MB") is drawn by the
        // system button and reported clipped although it shows whole.
        if issue.auditType == .textClipped, element.elementType == .staticText,
           app.buttons.matching(NSPredicate(format: "label CONTAINS %@", element.label)).allElementsBoundByIndex
               .contains(where: { $0.frame.contains(element.frame) && $0.label != element.label }) {
            return "the value of a system menu Picker"
        }
        // The navigation bar, the bottom toolbar and the search field are the system's: their
        // buttons are glass over whatever scrolls beneath (so the measured contrast changes with
        // the content), their text stops growing at the large sizes by design (a long press
        // shows it in the Large Content Viewer), and the search field's clear button is the
        // system's size.
        let frame = element.frame
        let bars = app.navigationBars.allElementsBoundByIndex + app.toolbars.allElementsBoundByIndex
            + app.searchFields.allElementsBoundByIndex
        if bars.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(frame) }) {
            switch issue.auditType {
            case .contrast, .dynamicType, .hitRegion, .textClipped:
                return "system bar or search field"
            default:
                return nil
            }
        }
        return nil
    }

    /// One line for the failure message: the audit type, what it says, and the element.
    static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        var element = "no element"
        if let found = issue.element {
            element = "\(found.elementType.rawValue) id='\(found.identifier)' label='\(found.label)' frame=\(found.frame)"
        }
        return "\(name(issue.auditType)): \(issue.compactDescription) — \(element) — \(issue.detailedDescription)"
    }

    static func name(_ type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "sufficientElementDescription"
        case .dynamicType: "dynamicType"
        case .textClipped: "textClipped"
        case .trait: "trait"
        default: "audit \(type.rawValue)"
        }
    }
}
