import Foundation
import TasksAgentTools
import XCTest
@testable import TasksCLIKit

/// `tasks review create`, `tasks review check` and `tasks review file`: the command line becomes
/// the create_review / get_review_file call the app's server takes.
final class TasksCLIReviewTests: XCTestCase {
    private let env = ["TASKS_AGENT": "claude", "TASKS_BOARD": "Pets"]

    private func plan(_ argv: [String], files: [String: String] = [:]) throws -> Plan {
        let input = InputSources(stdin: { Data() }, file: { path in
            guard let text = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
            return Data(text.utf8)
        })
        guard case .run(let plan) = try Commands.parse(argv, environment: env, input: input).0 else { throw CLIError.usage("not a call") }
        return plan
    }

    private func usage(_ argv: [String]) -> String {
        do { _ = try plan(argv); XCTFail("\(argv) parsed"); return "" } catch let error as CLIError { return error.message } catch { return "\(error)" }
    }

    func testCreateTurnsOptionsAndFilesIntoTheToolsArguments() throws {
        let made = try plan(["review", "create", "--card", "PETS-12", "--title", "Site, round 1", "--question", "Check it.",
                             "--on-accept", "testing", "--on-changes", "progress", "--comment-on-changes", "--assign-on-changes", "claude",
                             "--for", "sil", "--for", "herma", "--notify", "Urgent", "--due", "2026-12-02",
                             "--file", "shots/after-phone.png", "--file", "other/after-phone.png"],
                            files: ["shots/after-phone.png": "a", "other/after-phone.png": "b"])
        XCTAssertEqual(made.tool, "create_review")
        XCTAssertEqual(made.view, .reviewCreated)
        let a = made.arguments
        XCTAssertEqual(a["card"], .string("PETS-12"))
        XCTAssertEqual(a["notify"], .string("urgent"))
        XCTAssertEqual(a["due"], .string("2026-12-02"))
        XCTAssertEqual(a["for"], .array([.string("sil"), .string("herma")]))
        XCTAssertEqual(a["on_accept"], .object(["to": .string("testing")]))
        XCTAssertEqual(a["on_changes"], .object(["to": .string("in-progress"), "comment": .bool(true), "assign": .string("claude")]))
        XCTAssertNil(a["on_reject"])
        guard case .array(let items)? = a["items"] else { return XCTFail("no items") }
        XCTAssertEqual(items, [
            .object(["id": .string("after-phone"), "file_name": .string("after-phone.png"), "content_base64": .string(Data("a".utf8).base64EncodedString())]),
            .object(["id": .string("after-phone-2"), "file_name": .string("after-phone.png"), "content_base64": .string(Data("b".utf8).base64EncodedString())]),
        ])
        // Every argument is one the tool takes.
        let schema = ToolSchema(try XCTUnwrap(AgentTools.all.first { $0.name == "create_review" }))
        for key in a.keys { XCTAssertTrue(schema.properties.contains(key), key) }
    }

    func testCreateMergesAJSONObjectOverTheOptions() throws {
        let made = try plan(["review", "create", "--request", "PETS-12-site", "--file", "a.png",
                             #"{"items": [{"id": "b", "file_name": "b.png", "content_base64": "Yg=="}], "notify": "silent"}"#],
                            files: ["a.png": "a"])
        XCTAssertEqual(made.arguments["request"], .string("PETS-12-site"))
        XCTAssertEqual(made.arguments["notify"], .string("silent"))
        guard case .array(let items)? = made.arguments["items"] else { return XCTFail("no items") }
        XCTAssertEqual(items.count, 2)
    }

    func testCheckBuildsOneBrowserCheck() throws {
        let made = try plan(["review", "check", "--card", "PETS-12", "--title", "Onboarding page", "--url", "https://preview.example.app/onboarding",
                             "--size", "phone", "--size", "1080x1920", "--appearance", "Dark",
                             "--item", "The headline fits", "--item", "Download shows", "--on-accept", "testing"])
        guard case .array(let checks)? = made.arguments["checks"], case .object(let check)? = checks.first else { return XCTFail("no check") }
        XCTAssertEqual(check["id"], .string("onboarding-page"))
        XCTAssertEqual(check["url"], .string("https://preview.example.app/onboarding"))
        XCTAssertEqual(check["sizes"], .array([.string("phone"), .string("1080x1920")]))
        XCTAssertEqual(check["appearance"], .array([.string("dark")]))
        XCTAssertEqual(check["checklist"], .array([.string("The headline fits"), .string("Download shows")]))
        XCTAssertEqual(made.arguments["on_accept"], .object(["to": .string("testing")]))
        XCTAssertEqual(made.board, .fromCard("PETS-12", fallback: "Pets"))
    }

    func testRefusesIncompleteCommandLines() {
        XCTAssertTrue(usage(["review", "check", "--title", "T"]).contains("--url"))
        XCTAssertTrue(usage(["review", "create", "--file", "a.png"]).contains("Could not read") || usage(["review", "create"]).contains("--title"))
        XCTAssertTrue(usage(["review", "create", "--card", "P-1"]).contains("--title"))
        XCTAssertTrue(usage(["review", "create", "--title", "T", "--comment-on-changes"]).contains("--on-changes"))
        XCTAssertTrue(usage(["review", "create", "--title", "T", "stray"]).contains("unexpected"))
        XCTAssertTrue(usage(["review", "file", "r"]).contains("path"))
    }

    func testFileAsksForOneFileAndSaysWhereItGoes() throws {
        let made = try plan(["review", "file", "PETS-12-site", "results/page-phone.png", "-o", "phone.png"])
        XCTAssertEqual(made.tool, "get_review_file")
        XCTAssertEqual(made.arguments["request"], .string("PETS-12-site"))
        XCTAssertEqual(made.arguments["path"], .string("results/page-phone.png"))
        XCTAssertEqual(made.view, .reviewFile(output: "phone.png"))
        XCTAssertEqual(try plan(["review", "file", "r", "a.png"]).view, .reviewFile(output: nil))
    }
}
