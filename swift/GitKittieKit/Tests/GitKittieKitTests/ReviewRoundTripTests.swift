import Foundation
import Testing
import Yams
@testable import GitKittieKit

// Writes keep a request's text: what a write does not change stays byte for byte as it was
// (ReviewYAMLSplice), whoever wrote the file and in whatever YAML style.

/// The lines of the entry of `id` in a `review.md`: from its dash line up to the next line
/// that is not indented deeper than that dash.
func entryRange(_ lines: [String], id: String) -> Range<Int>? {
    guard let idLine = lines.firstIndex(where: { $0.range(of: #"^\s*(- )?id:\s*["']?\#(NSRegularExpression.escapedPattern(for: id))["']?\s*$"#, options: .regularExpression) != nil }) else { return nil }
    guard let start = lines[...idLine].lastIndex(where: { $0.range(of: #"^\s*- "#, options: .regularExpression) != nil }) else { return nil }
    let dash = lines[start].prefix { $0 == " " }.count
    let end = lines[(start + 1)...].firstIndex { line in
        !line.trimmingCharacters(in: .whitespaces).isEmpty && line.prefix { $0 == " " }.count <= dash
    } ?? lines.count
    return start..<end
}

/// The line numbers of `before` that `after` no longer has.
func removedLines(_ before: String, _ after: String) -> [Int] {
    let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
    return b.difference(from: a).compactMap { change in
        if case .remove(let offset, _, _) = change { return offset }
        return nil
    }
}

@Suite struct ReviewRoundTripTests {
    static let handWritten = """
    ---
    config: review
    id: PETS-1
    title: "Pets, round 1"   # what to look at
    for: [sil]
    on_accept: { to: testing }
    items:
      - id: a
        file: a.png
        note: "Quoted, with: colon"
        comments: [{ by: sil, at: 2026-11-08T15:00:00Z, text: "Flow style" }]
      - id: b
        file: b.png
        status: pending
    # trailing comment
    custom_agent_key:
      nested: [1, 2]
    ---

    Notes stay.
    """

    @Test func aWriteThatChangesNothingKeepsTheFile() throws {
        let same = try Review.setNotify(Self.handWritten.replacingOccurrences(of: "for: [sil]", with: "for: [sil]\nnotify: normal"), .normal)
        #expect(same == Self.handWritten.replacingOccurrences(of: "for: [sil]", with: "for: [sil]\nnotify: normal"))
    }

    @Test func aDecisionChangesOnlyItsOwnEntry() throws {
        let next = try Review.applyDecision(Self.handWritten, itemID: "b", status: .approved, by: "sil", at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(next.contains("title: \"Pets, round 1\"   # what to look at"))
        #expect(next.contains("    comments: [{ by: sil, at: 2026-11-08T15:00:00Z, text: \"Flow style\" }]"))
        #expect(next.contains("# trailing comment\ncustom_agent_key:\n  nested: [1, 2]"))
        #expect(next.hasSuffix("---\n\nNotes stay.\n") || next.hasSuffix("---\n\nNotes stay."))
        let lines = Self.handWritten.components(separatedBy: "\n")
        let range = try #require(entryRange(lines, id: "b"))
        #expect(removedLines(Self.handWritten, next).allSatisfy(range.contains))
        let item = Review.parse(next, folder: "x").items[1]
        #expect(item.status == .approved && item.decidedBy == "sil")
    }

    @Test func aCommentOnAFlowListRewritesOnlyThatKey() throws {
        let next = try Review.appendComment(Self.handWritten, itemID: "a", by: "sil", body: "Second", at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(next.contains("    note: \"Quoted, with: colon\""))
        #expect(next.contains("  - id: b\n    file: b.png\n    status: pending"))
        #expect(Review.parse(next, folder: "x").items[0].comments.map(\.text) == ["Flow style", "Second"])
    }

    @Test func newEntriesTakeTheListsIndentation() throws {
        let next = try Review.appendItems(Self.handWritten, [Review.NewItem(id: "c", file: "c.png")])
        #expect(next.contains("  - id: b\n    file: b.png\n    status: pending\n  - id: c\n    file: c.png\n"))
        #expect(Review.parse(next, folder: "x").items.map(\.id) == ["a", "b", "c"])
    }

    @Test func checkAnswersAndActionRunsRoundTrip() throws {
        let text = """
        ---
        id: PETS-3
        checks:
        - id: page
          url: https://example.com
          sizes: [phone]
          checklist:
          - { id: hero, text: Headline fits }
          status: pending
        ---
        """
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var next = try Review.applyCheckAnswer(text, checkID: "page", key: "phone", line: "hero", result: .fail, note: "Wraps", viewport: "402x874", by: "sil", at: at)
        next = try Review.applyCheckScreenshot(next, checkID: "page", key: "phone", path: ReviewCheck.screenshotPath(check: "page", key: "phone"), by: "sil", at: at)
        next = try Review.applyCheckDecision(next, checkID: "page", status: .changesRequested, by: "sil", at: at)
        next = try Review.appendCheckComment(next, checkID: "page", by: "sil", body: "Phone: wraps", at: at)
        next = try Review.appendActionRun(next, ActionRun(on: .changes, card: "PETS-3", from: "in-review", to: "in-progress", result: .moved,
                                                          by: "sil", at: Review.timestamp(at), before: ["assignee": "claude", "reviewer": nil]))
        next = try Review.markActionRunUndone(next, index: 0, at: at.addingTimeInterval(5))
        let review = Review.parse(next, folder: "x")
        let check = try #require(review.checks.first)
        #expect(check.results["phone"] == CheckResult(viewport: "402x874", by: "sil", at: Review.timestamp(at), screenshot: "results/page-phone.png",
                                                      answers: ["hero": CheckAnswer(result: .fail, note: "Wraps", at: Review.timestamp(at))]))
        #expect(check.status == .changesRequested && check.comments.count == 1)
        #expect(check.failures.map(\.item) == ["hero"])
        #expect(review.outcome == .changes)
        #expect(review.actionsRun.first?.undoneAt == Review.timestamp(at.addingTimeInterval(5)))
        #expect(review.actionsRun.first?.before == ["assignee": "claude", "reviewer": nil])
        #expect(next.contains("  sizes: [phone]\n  checklist:\n  - { id: hero, text: Headline fits }"))
        #expect(throws: ReviewError.noteNeeded) { try Review.applyCheckAnswer(text, checkID: "page", key: "phone", line: "hero", result: .note, by: "sil") }
        #expect(throws: ReviewError.checkLineNotFound(check: "page", line: "nope")) { try Review.applyCheckAnswer(text, checkID: "page", key: "phone", line: "nope", result: .pass, by: "sil") }
        #expect(throws: ReviewError.checkNotFound("gone")) { try Review.applyCheckDecision(text, checkID: "gone", status: .approved, by: "sil") }
        #expect(throws: ReviewError.actionRunNotFound(4)) { try Review.markActionRunUndone(next, index: 4) }
        // Taking an answer back.
        let back = try Review.applyCheckAnswer(next, checkID: "page", key: "phone", line: "hero", result: nil, by: "sil", at: at)
        #expect(Review.parse(back, folder: "x").checks[0].results["phone"]?.answers.isEmpty == true)
    }

    @Test func renderWritesTheNewKeys() throws {
        let text = try Review.render(
            id: "PETS-4-site", project: "Pets", card: "PETS-4", title: "Site", question: nil, requestedBy: "claude",
            at: Date(timeIntervalSince1970: 1_800_000_000), notes: nil, items: [],
            checks: [Review.NewCheck(id: "page", url: "https://example.com", sizes: [CheckSize.presets[1], CheckSize(id: "kiosk", label: "Kiosk", width: 1080, height: 1920, ua: .desktop)],
                                     appearance: [.light, .dark], checklist: [CheckLine(id: "hero", text: "Headline fits")],
                                     actions: ReviewActions(accept: [ReviewAction(move: "PETS-9", to: "testing")]))],
            notify: .urgent,
            options: Review.RequestOptions(assignedTo: ["sil"], due: "2026-12-02",
                                           actions: ReviewActions(accept: [ReviewAction(to: "testing")], changes: [ReviewAction(to: "in-progress", comment: true, assign: "claude")])))
        let review = Review.parse(text, folder: "Pets/review/PETS-4-site")
        #expect(review.assignedTo == ["sil"] && review.due == "2026-12-02" && review.notify == .urgent)
        #expect(review.actions.changes == [ReviewAction(to: "in-progress", comment: true, assign: "claude")])
        #expect(review.items.isEmpty && review.checks.count == 1)
        #expect(review.checks[0].sizes == [CheckSize.presets[1], CheckSize(id: "kiosk", label: "Kiosk", width: 1080, height: 1920, ua: .desktop)])
        #expect(review.checks[0].actions.accept == [ReviewAction(move: "PETS-9", to: "testing")])
        #expect(text.contains("for: [sil]") && text.contains("on_accept: {to: testing}") || text.contains("on_accept: { to: testing }") || text.contains("on_accept: {to: testing}"))
        #expect(!text.contains("items:"))
    }

    /// `GITKITTIE_REVIEW_FIXTURES` at a copy of the board's `<Project>/review/<request>/review.md`
    /// files (they are Sil's and stay out of this repository): every real request reads and writes
    /// back unchanged, and a decision on its first item changes nothing outside that item.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GITKITTIE_REVIEW_FIXTURES"] != nil))
    func everyRealRequestRoundTrips() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GITKITTIE_REVIEW_FIXTURES"]!)
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent == "review.md" }
        #expect(!files.isEmpty)
        var decided = 0, withItems = 0
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingLastPathComponent().lastPathComponent
            // Unchanged: the same bytes (a no-op write through the writer).
            let unchanged = try Review.mutateFrontmatter(text) { _ in }
            #expect(unchanged == text, "\(name) changed on a write that changed nothing")
            let review = Review.parse(text, folder: name)
            guard let item = review.items.first(where: { $0.status == .pending }) ?? review.items.first else { continue }
            withItems += 1
            let status: ReviewStatus = item.status == .approved ? .rejected : .approved
            let next = try Review.applyDecision(text, itemID: item.id, status: status, by: "tester", at: Date(timeIntervalSince1970: 1_800_000_000))
            let after = Review.parse(next, folder: name)
            #expect(after.items.first { $0.id == item.id }?.status == status, "\(name): decision not written")
            // Everything else reads the same.
            #expect(after.items.filter { $0.id != item.id } == review.items.filter { $0.id != item.id }, "\(name): other items changed")
            #expect(after.questions == review.questions && after.checks == review.checks && after.title == review.title
                    && after.body == review.body && after.notify == review.notify, "\(name): request changed")
            // And keeps its text outside that item (a mended request is written mended).
            if (try? Yams.compose(yaml: BoardMarkdown.splitFrontmatter(text).0 ?? "")) != nil {
                let range = try #require(entryRange(text.components(separatedBy: "\n"), id: item.id), "\(name): no entry for \(item.id)")
                let outside = removedLines(text, next).filter { !range.contains($0) }
                #expect(outside.isEmpty, "\(name): lines outside \(item.id) changed: \(outside)")
                decided += 1
            }
        }
        print("round-tripped \(files.count) real requests; \(withItems) with items, \(decided) of them (the valid YAML ones) decided with only their item's lines changed")
    }
}
