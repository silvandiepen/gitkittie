import XCTest
@testable import GitKittieKit

/// Runs the real on-device model, so only where it is available and when asked:
/// `ON_DEVICE_AI=1 swift test --filter OnDeviceDraftLiveTests`.
final class OnDeviceDraftLiveTests: XCTestCase {
    static let context = AITicketContext(
        projectName: "GitKittie", lanes: ["To do", "In Progress", "In Review", "Testing", "Done"],
        priorities: ["P0", "P1", "P2", "P3"], types: ["feature", "fix", "chore", "docs"],
        epics: ["gitfolder", "gitkanban-core", "gitkit-swift", "gitkanban-macos", "gitkanban-ios", "monorepo-setup"],
        existingTicketTitles: ["Fix card numbering for tasks created on the phone", "Add a review section across boards",
                               "Show review count in the board header", "Make the icon picker searchable"])

    static let cases: [(name: String, input: String)] = [
        ("two marks, no screen text", """
        A screenshot belongs to these notes, but you cannot see it.

        Notes the person wrote on the screenshot, each pointing at something in it:
        1. Make this just an edit button.
        2. Tititlw is still the first comment.
        """),
        ("seven marks with screen text", """
        A screenshot belongs to these notes, but you cannot see it.

        The user's own pointers. Follow them and keep their intent:
        Inwant to position the camera, the height and it should stay there and not automatically go back.

        Notes the person wrote on the screenshot, each pointing at something in it:
        1. Other helps don’t walk normal and don’t actually position to push
        2. Not holding the cannon
        3. Cannon is positioned sideways
        4. Sky is all black?
        5. This info take up so much of the screen its insane.
        6. Why would I let go?
        7. Pushing up a hill is wayyyyyy tooo slow.

        Text visible in the screenshot:
        Push the cannon to the fort
        Helpers 2/3
        Hold to push
        Let go
        Distance 34 m
        Cannon weight 400 kg  Slope 12%  Speed 0.2 m/s

        The picture appears to show: outdoor, landscape, sky.
        """),
        ("one typed line, no image", "The user's own pointers. Follow them and keep their intent:\nanimals walk through trees and stones"),
    ]

    func testDraftsFromPhoneStyleInput() async throws {
        guard ProcessInfo.processInfo.environment["ON_DEVICE_AI"] != nil else { throw XCTSkip("Set ON_DEVICE_AI=1") }
        if let reason = OnDeviceAI.unavailableReason { throw XCTSkip("On-device model: \(reason)") }
        for (name, input) in Self.cases {
            let started = Date()
            do {
                let ticket = try await OnDeviceAI.draftTicket(input: input, context: Self.context)
                print("=== \(name): \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                print("TITLE: \(ticket.title)\nPRIORITY: \(ticket.priority ?? "-")  TYPE: \(ticket.type ?? "-")\nDESCRIPTION:\n\(ticket.description)\n")
                XCTAssertFalse(ticket.description.isEmpty)
            } catch {
                print("=== \(name): FAILED after \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(error)")
            }
        }
    }
}
