import XCTest

/// One issue an accessibility audit reported, copied out of the audit's handler: the handler
/// only records, and the policy below looks at the app after the audit has finished.
@MainActor
struct AuditFinding {
    struct Element {
        var type: XCUIElement.ElementType
        var identifier: String
        var label: String
        var frame: CGRect
    }

    var type: XCUIAccessibilityAuditType
    var summary: String
    /// The audit's longer explanation: for a finding without an element it is all there is.
    var detail: String
    var element: Element?

    init(_ issue: XCUIAccessibilityAuditIssue) {
        type = issue.auditType
        summary = issue.compactDescription
        detail = issue.detailedDescription
        if let found = issue.element {
            element = Element(type: found.elementType, identifier: found.identifier, label: found.label, frame: found.frame)
        }
    }

    /// One line for the failure message: the audit type, what it says, and the element.
    var description: String {
        let what = element.map { "\($0.type.rawValue) id='\($0.identifier)' label='\($0.label)' frame=\($0.frame)" } ?? "no element (\(detail))"
        return "\(AccessibilityAuditPolicy.name(type)): \(summary) — \(what)"
    }
}

/// Which accessibility audit issues the UI tests skip, and why (GKM-061, GKM-081). Only issues in a
/// system control the app can't change are skipped, plus one false report, each with its
/// reason written here. Everything else fails the test.
@MainActor
enum AccessibilityAuditPolicy {
    /// The reason a finding is skipped, or nil when it counts.
    static func skipReason(_ finding: AuditFinding, in app: XCUIApplication) -> String? {
        if finding.type == .dynamicType {
            return DynamicTypeAllowlist.skipReason(finding, in: app)
        }
        // A few reports name no element (elementDetection "Potentially inaccessible text",
        // textClipped on the list): there is nothing to check them against but the screenshot,
        // where nothing on those screens is cut or unlabelled. They are printed, not failed.
        guard let element = finding.element else {
            // Contrast without an element comes from the add-account and compose sheets, where the
            // only faint text is the system's text field placeholder.
            return [.elementDetection, .textClipped, .contrast].contains(finding.type)
                ? "names no element; the screenshot shows nothing cut, unlabelled or faint but the system's placeholders" : nil
        }
        // Under or inside the system keyboard (its suggestion bar has three unlabelled cells):
        // text behind the keyboard measures as unreadable, and the keyboard is the system's.
        let keyboard = app.keyboards.firstMatch
        // (The suggestion bar sits just above the keyboard element.)
        if keyboard.exists, element.frame.maxY > keyboard.frame.minY - 48 {
            return "behind or inside the system keyboard"
        }
        // A message row's subject over several lines at Accessibility XXXL is reported clipped
        // while every line shows (GKM-061 screenshot, run 21); the row reads it whole to
        // VoiceOver too. Only when the row's label carries the whole text.
        if finding.type == .textClipped, element.type == .staticText,
           app.descendants(matching: .any).matching(identifier: "messageRow").allElementsBoundByIndex
               .contains(where: { $0.frame.contains(element.frame) && $0.label.contains(element.label) }) {
            return "a message row's text, shown whole and read whole"
        }
        // The same for a row of the iPad's sidebar: "Drafts" stacked under its icon at
        // Accessibility XXXL, and "Add Account" at the default size, are reported clipped while
        // they show whole (GKM-064 screenshots, full runs 1 and 2). Only when the row (a mailbox,
        // or a button in the sidebar) is labelled with exactly that text.
        let sidebarRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'mailbox.'"))
            .allElementsBoundByIndex
            + app.collectionViews.containing(NSPredicate(format: "identifier BEGINSWITH 'mailbox.'"))
                .buttons.allElementsBoundByIndex
        if finding.type == .textClipped, element.type == .staticText,
           sidebarRows.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(element.frame) && $0.label == element.label }) {
            return "a sidebar row's text, shown whole and read whole"
        }
        // An account's name above its folders is one line, shortened in the middle when it
        // doesn't fit, on purpose (an address wrapped mid-domain otherwise); its row reads it
        // whole. Reported clipped on iPhone while it showed whole (GKM-064, iPhone run 1). Only
        // the header whose sync status names that same account.
        if finding.type == .textClipped, element.type == .staticText,
           app.staticTexts["syncStatus.\(element.label)"].exists {
            return "an account's header, one line by design"
        }
        // A one-line SwiftUI TextField (the subject, the account name) is reported clipped while
        // it shows all its text and its placeholder whole (GKM-061 screenshots); the field's text
        // layout is the system's.
        if finding.type == .textClipped, element.type == .textField || element.type == .secureTextField {
            return "system text field showing its whole text"
        }
        // The value inside a Form menu Picker ("Older mail  Up to 500 MB") is drawn by the
        // system button and reported clipped although it shows whole.
        if finding.type == .textClipped, element.type == .staticText,
           app.buttons.matching(NSPredicate(format: "label CONTAINS %@", element.label)).allElementsBoundByIndex
               .contains(where: { $0.frame.contains(element.frame) && $0.label != element.label }) {
            return "the value of a system menu Picker"
        }
        // The navigation bar, the bottom toolbar and the search field are the system's: their
        // buttons are glass over whatever scrolls beneath (so the measured contrast changes with
        // the content), their text stops growing at the large sizes by design (a long press
        // shows it in the Large Content Viewer), and the search field's clear button is the
        // system's size.
        let bars = app.navigationBars.allElementsBoundByIndex + app.toolbars.allElementsBoundByIndex
            + app.searchFields.allElementsBoundByIndex
        // Text that runs on below the screen, under the bottom toolbar, is measured through the
        // toolbar's glass; text that runs on below the end of its list (the bottom of an iPad
        // form sheet, GKM-064) is measured half-scrolled out of view.
        if finding.type == .contrast,
           app.toolbars.allElementsBoundByIndex.contains(where: { $0.frame.intersects(element.frame) })
            || element.frame.maxY > app.windows.firstMatch.frame.maxY {
            return "partly under the system's bottom toolbar"
        }
        // Text scrolled partly under a navigation bar (the top of an iPad form sheet, GKM-064)
        // is measured through the bar's glass.
        if finding.type == .contrast,
           app.navigationBars.allElementsBoundByIndex.contains(where: { $0.frame.intersects(element.frame) }) {
            return "partly under the system's navigation bar"
        }
        if finding.type == .contrast, element.type == .staticText,
           app.collectionViews.allElementsBoundByIndex.contains(where: {
               $0.frame.intersects(element.frame) && element.frame.minY < $0.frame.maxY && element.frame.maxY > $0.frame.maxY
           }) {
            return "partly scrolled out of the bottom of its list"
        }
        // In portrait the iPad lays the mailboxes over the list and the conversation and dims
        // those (GKM-064): their text is measured through the system's dimming. Until the
        // sidebar goes away they can't be read or used, and the same screens are audited
        // without it.
        let window = app.windows.firstMatch.frame
        if finding.type == .contrast, UIDevice.current.userInterfaceIdiom == .pad, window.width < window.height,
           let sidebar = app.collectionViews.containing(NSPredicate(format: "identifier BEGINSWITH 'mailbox.'"))
               .allElementsBoundByIndex.first(where: { window.intersects($0.frame) }),
           !sidebar.frame.intersects(element.frame) {
            return "dimmed behind the sidebar the iPad lays over the list in portrait"
        }
        if bars.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(element.frame) }) {
            switch finding.type {
            case .contrast, .hitRegion, .textClipped:
                return "system bar or search field"
            default:
                return nil
            }
        }
        return nil
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

/// The only places a Dynamic Type finding is skipped (GKM-081). Each is a container the system
/// draws, where SwiftUI text that does grow is reported as "partially unsupported": at
/// Accessibility XXXL the same "No mail yet", "Servers", "Incoming (IMAP)" and sidebar rows fill
/// the screen (GKM-061 and GKM-064 screenshots), and testMainScreensAtLargestTextSize fails text
/// that doesn't fit there as clipped.
///
/// Everything else that names an element fails: "unsupported" (a fixed point size, which
/// doesn't grow at all) anywhere, and "partially unsupported" outside these containers.
@MainActor
enum DynamicTypeAllowlist {
    struct Container {
        var name: String
        var reason: String
        var contains: @MainActor (AuditFinding.Element, XCUIApplication) -> Bool
    }

    static let partially = "Dynamic Type font sizes are partially unsupported"

    static let containers: [Container] = [
        Container(
            name: "system bar",
            reason: "the navigation bar, bottom toolbar and search field cap their text by design; a long press shows it in the Large Content Viewer",
            contains: { element, app in
                (app.navigationBars.allElementsBoundByIndex + app.toolbars.allElementsBoundByIndex
                    + app.searchFields.allElementsBoundByIndex)
                    .contains { $0.frame.insetBy(dx: -1, dy: -1).contains(element.frame) }
            }),
        Container(
            name: "Form or List",
            reason: "SwiftUI text in a Form or List row, section header or footer (Settings, the account form, the sidebar) grows with its text style",
            contains: { element, app in
                // The message rows are a List too, but they are the app's own layout: their text
                // is never skipped.
                let messageRows = app.descendants(matching: .any).matching(identifier: "messageRow").allElementsBoundByIndex
                return element.type == .staticText
                    && !messageRows.contains { $0.frame.contains(element.frame) && $0.label.contains(element.label) }
                    && app.collectionViews.allElementsBoundByIndex
                        .contains { $0.frame.insetBy(dx: -1, dy: -1).contains(element.frame) }
            }),
        Container(
            name: "ContentUnavailableView",
            reason: "the empty list's \"No mail yet\", its description and its Add Account button are the system's empty-state view, in its text styles",
            contains: { element, app in
                (element.type == .staticText
                    && (element.label == "No mail yet" || element.label.hasPrefix("Add an account. Mail keeps every message")))
                    || (element.type == .button && element.identifier == "addAccountButton"
                        && app.staticTexts["No mail yet"].exists)
            }),
    ]

    static let unsupported = "Dynamic Type font sizes are unsupported"

    static func skipReason(_ finding: AuditFinding, in app: XCUIApplication) -> String? {
        guard let element = finding.element else {
            // The one finding without an element (GKM-083): "unsupported", on the iPad's Add
            // Account sheet, only while the form is scrolled down to the servers; 3 of 3 audits
            // then, none at the top or on iPhone. Bisected on iPad Pro 13-inch (M5), iOS 26.2: it
            // stays with the Security picker as a menu, segmented or removed, the top scroll edge
            // effect soft, hard or hidden, the scroll indicators hidden, and the servers footer
            // or the User name row removed. Every text in the form uses a text style (scripts/
            // test.sh refuses fixed sizes), and the audit names nothing to look at. Anything else
            // without an element fails.
            let addAccount = app.navigationBars["Add Account"].exists
            guard finding.summary == unsupported, addAccount, UIDevice.current.userInterfaceIdiom == .pad else { return nil }
            return "names no element: the iPad's scrolled Add Account sheet (GKM-083)"
        }
        guard finding.summary == partially else { return nil }
        return containers.first { $0.contains(element, app) }.map { "\($0.name): \($0.reason)" }
    }
}
