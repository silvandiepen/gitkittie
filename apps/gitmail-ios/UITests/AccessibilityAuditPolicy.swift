import XCTest

/// Which accessibility audit issues the UI tests skip, and why (GKM-061). Only issues in a
/// system control the app can't change are skipped; each has its reason written here.
/// Everything else fails the test.
@MainActor
enum AccessibilityAuditPolicy {
    /// The reason an issue is skipped, or nil when it counts.
    static func systemIssue(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> String? {
        guard let element = issue.element else { return nil }
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
        return "\(name(issue.auditType)): \(issue.compactDescription) — \(element)"
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
