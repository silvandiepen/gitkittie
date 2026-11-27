import Foundation
import Testing
import Yams
@testable import GitKittieKit

// The top of a review request: its notes (the Markdown under the frontmatter), title and
// question as the review screens draw them. Nothing of the Markdown or the frontmatter may
// show as raw text (GITKITTIE-107).

/// Raw Markdown or frontmatter left in drawn text, one finding per offending line.
func markdownLeaks(_ blocks: [MarkdownBlocks.Block]) -> [String] {
    blocks.flatMap { block -> [String] in
        if case .code = block { return [] }
        return MarkdownBlocks.renderedText([block]).components(separatedBy: "\n").compactMap(markdownLeak)
    }
}

func markdownLeak(_ line: String) -> String? {
    let checks: [(String, String)] = [
        (#"^\s{0,3}#{1,6}\s"#, "heading marks"),
        (#"!\["#, "picture syntax"),
        (#"\]\("#, "link syntax"),
        (#"\*\*|__"#, "bold marks"),
        (#"`"#, "code marks"),
        (#"^\s*\|?\s*:?-{3,}:?\s*\|"#, "table rule"),
        (#"^-{3}\s*$"#, "frontmatter fence"),
        (#"^(config|items|questions|requested_by|requested_at):"#, "frontmatter key"),
        (#"<(img|details|summary|br|div|p|a)\b"#, "HTML"),
    ]
    for (pattern, name) in checks where line.range(of: pattern, options: .regularExpression) != nil {
        return "\(name): \(line.prefix(120))"
    }
    return nil
}

@Suite struct ReviewNotesTests {
    @Test func picturesOnTheirOwnLinesBecomeOneRow() {
        let blocks = MarkdownBlocks.parse("""
        ## Preview

        ![day 1](day1-near.jpg)
        ![day 2](day2-near.jpg "Second day")

        Text after.
        """)
        #expect(blocks == [
            .heading(level: 2, text: "Preview"),
            .images([.init(alt: "day 1", source: "day1-near.jpg"), .init(alt: "day 2", source: "day2-near.jpg")]),
            .paragraph("Text after."),
        ])
    }

    @Test func linkedPictureKeepsWhereItLinksTo() {
        let blocks = MarkdownBlocks.parse("[![One shared world, designer view](one-world-overview-preview.jpg)](one-world-overview.jpg)")
        #expect(blocks == [.images([.init(alt: "One shared world, designer view", source: "one-world-overview-preview.jpg",
                                          link: "one-world-overview.jpg")])])
    }

    @Test func pictureInsideTextIsTakenOutOfIt() {
        let blocks = MarkdownBlocks.parse("Left is before ![before](a.png) and right is after ![after](b.png).")
        #expect(blocks == [
            .paragraph("Left is before and right is after ."),
            .images([.init(alt: "before", source: "a.png"), .init(alt: "after", source: "b.png")]),
        ])
    }

    @Test func notesInTheShapesAgentsWriteRenderWithoutRawMarkdown() {
        let notes = """
        # Trading post: panel and prices (ARVIK-461)

        Draft PR: https://github.com/example/pull/1. Made by `tools/author.py` (**original** geometry).

        ## Round 3 (2026-11-26): your round 2 notes

        | Slot | Who |
        |------|-----|
        | m1 | **Vikings** man |
        | m2 | `rus` woman |

        1. Registers the shipped mesh.
        2. See [gallery](index.html).

        ![464r2-vikings-close.jpg](464r2-vikings-close.jpg)
        [![overview](o-preview.jpg)](o.jpg)

        > [!NOTE]
        > Before = current main, After = branch `feat/x`.

        #365 ships.
        """
        let blocks = MarkdownBlocks.parse(notes)
        #expect(markdownLeaks(blocks).isEmpty, "\(markdownLeaks(blocks))")
    }

    @Test func handWrittenSlipsInTheFrontmatterAreMendedNotShownAsAnEmptyRequest() throws {
        // As written by hand in real requests: a double-quoted note with quotes inside it, and
        // a plain note with a colon in it. Neither is valid YAML.
        let text = """
        ---
        config: review
        id: SHOP-1-panel
        title: Shop panel
        items:
          - id: completed-buy-v2
            file: completed-buy-v2.png
            note: "First trade done: one line, "Bought 24 stone from Fair Tide", then it's closed."
            status: changes-requested
          - id: pair-good
            file: good.png
            note: Diagnostic pair: the good state.
            status: pending
        questions:
          - id: q
            question: Which?
            detail: |-
              Kept as it is: "quoted", and: colons.
            options: [a, b]
        ---

        Notes.
        """
        let request = Review.parse(text, folder: "Shop/review/SHOP-1-panel")
        #expect(request.problem == nil)
        #expect(request.items.map(\.id) == ["completed-buy-v2", "pair-good"])
        #expect(request.items[0].note == #"First trade done: one line, "Bought 24 stone from Fair Tide", then it's closed."#)
        #expect(request.items[0].status == .changesRequested)
        #expect(request.items[1].note == "Diagnostic pair: the good state.")
        #expect(request.questions.first?.detail == #"Kept as it is: "quoted", and: colons."#)
        #expect(request.body.trimmingCharacters(in: .whitespacesAndNewlines) == "Notes.")

        // A decision can be written to it: the file is written back as valid YAML.
        let decided = try Review.applyDecision(text, itemID: "pair-good", status: .approved, by: "sil")
        let reread = Review.parse(decided, folder: "Shop/review/SHOP-1-panel")
        #expect(reread.items.map(\.status) == [.changesRequested, .approved])
        #expect(reread.items[0].note == request.items[0].note)
    }

    @Test func frontmatterThatCannotBeMendedIsReportedWithItsLine() {
        let text = "---\nid: broken\nitems: [\n  - id: a\n---\n\nNotes.\n"
        let request = Review.parse(text, folder: "P/review/broken")
        #expect(request.items.isEmpty)
        #expect(request.problem?.hasPrefix("Line ") == true, "\(request.problem ?? "nil")")
    }

    @Test func validFrontmatterHasNoProblem() {
        let request = Review.parse("---\nid: a\nitems:\n  - id: x\n    file: x.png\n---\n", folder: "P/review/a")
        #expect(request.problem == nil)
        #expect(request.items.count == 1)
    }

    /// Every real review request on the board: its frontmatter is read (or the problem with
    /// it is named), and its title, question and notes draw without raw Markdown or
    /// frontmatter. The requests are Sil's own and stay out of this public repository: point
    /// `GITKITTIE_REVIEW_FIXTURES` at a folder holding `<Project>/review/<request>/review.md`
    /// (a read-only copy of the board) to run it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GITKITTIE_REVIEW_FIXTURES"] != nil))
    func everyRealReviewRendersItsTopWithoutRawMarkdown() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GITKITTIE_REVIEW_FIXTURES"]!)
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent == Review.fileName }
            .sorted { $0.path < $1.path }
        #expect(!files.isEmpty)
        var unreadable: [String] = []
        var mended: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let folder = file.deletingLastPathComponent().path.replacingOccurrences(of: root.path + "/", with: "")
            let request = Review.parse(text, folder: folder)
            let name = file.deletingLastPathComponent().lastPathComponent
            if let problem = request.problem { unreadable.append("\(name): \(problem)") }
            #expect(request.problem == nil, "\(name): \(request.problem ?? "")")
            #expect(!request.items.isEmpty || !request.questions.isEmpty, "\(name) has nothing to review")
            if let yaml = BoardMarkdown.splitFrontmatter(text).frontmatter, (try? Yams.compose(yaml: yaml)) == nil {
                mended.append("\(name): \(request.items.count) items, \(request.summary.pending) waiting")
            }
            #expect(!request.body.contains("config: review"), "\(name): frontmatter in the notes")
            let top = [request.title, request.question].compactMap { $0 }.map { MarkdownBlocks.Block.paragraph($0) }
            let leaks = markdownLeaks(top + MarkdownBlocks.parse(request.body))
            #expect(leaks.isEmpty, "\(name): \(leaks.prefix(5))")
            for item in request.items {
                if let note = item.note, let leak = markdownLeak(String(MarkdownBlocks.inline(note).characters)) {
                    Issue.record("\(name)/\(item.id) note: \(leak)")
                }
            }
        }
        print("Real reviews read: \(files.count); mended frontmatter: \(mended.count); unreadable: \(unreadable.count)\n"
              + (mended + unreadable).joined(separator: "\n"))
    }
}

@Suite struct ReviewFilterTests {
    private let request = Review.parse("""
    ---
    id: R-1
    items:
      - id: a
        file: a.png
        status: approved
      - id: b1
        file: b1.png
        group: b
        pick: one
        status: rejected
      - id: c
        file: c.png
        group: c
        status: approved
      - id: b2
        file: b2.png
        group: b
        status: pending
      - id: d
        file: d.png
        status: changes-requested
        handled_at: 2026-11-20T10:00:00Z
    questions:
      - id: q1
        question: Which?
        options: [x, y]
        answer: [x]
        answered_at: 2026-11-20T10:00:00Z
      - id: q2
        question: And?
        options: [x, y]
    ---
    """, folder: "P/review/R-1")

    @Test func entriesAreQuestionsFirstThenItemsGroupByGroup() {
        #expect(request.entries.map(\.id) == ["question:q1", "question:q2", "item:a", "item:b1", "item:b2", "item:c", "item:d"])
        #expect(request.entries.filter(\.isWaiting).map(\.id) == ["question:q2", "item:b2"])
    }

    @Test func countsFollowTheSummary() {
        let s = request.summary
        #expect(ReviewFilter.waiting.count(in: s) == 2)
        #expect(ReviewFilter.answered.count(in: s) == 5)
        #expect(ReviewFilter.all.count(in: s) == 7)
    }

    @Test func waitingHidesWhatIsSettledButKeepsAnOpenPickOneGroupTogether() {
        let hidden = request.hiddenIDs(for: .waiting)
        // b1 is decided but its group still has b2 waiting: they are chosen between together.
        #expect(hidden.items == ["a", "c", "d"])
        #expect(hidden.questions == ["q1"])
    }

    @Test func waitingHidesDecidedFilesOfAGroupThatIsNotPickOne() {
        let request = Review.parse("""
        ---
        id: R-2
        items:
          - id: s1
            file: s1.png
            group: specimen
            status: approved
          - id: s2
            file: s2.png
            group: specimen
            status: pending
        ---
        """, folder: "P/review/R-2")
        #expect(request.hiddenIDs(for: .waiting).items == ["s1"])
        #expect(!request.isStillOpen(request.items[0]))
    }

    @Test func answeredHidesWhatStillWaits() {
        let hidden = request.hiddenIDs(for: .answered)
        #expect(hidden.items == ["b2"])
        #expect(hidden.questions == ["q2"])
        #expect(request.hiddenIDs(for: .all).items.isEmpty)
    }

    @Test func handledItemsCountAsAnswered() {
        // The agent acting on a decision does not make it wait again.
        #expect(!ReviewEntry.item(request.items.first { $0.id == "d" }!).isWaiting)
    }

    @Test func nextWaitingGoesOnAndWrapsRound() {
        let entries = request.entries
        #expect(ReviewEntry.nextWaiting(after: nil, in: entries)?.id == "question:q2")
        #expect(ReviewEntry.nextWaiting(after: "question:q2", in: entries)?.id == "item:b2")
        #expect(ReviewEntry.nextWaiting(after: "item:b2", in: entries)?.id == "question:q2")
        #expect(ReviewEntry.nextWaiting(after: "item:c", in: entries)?.id == "question:q2")
        let done = Review.parse("---\nid: x\nitems:\n  - id: a\n    file: a.png\n    status: approved\n---\n", folder: "P/review/x")
        #expect(ReviewEntry.nextWaiting(after: nil, in: done.entries) == nil)
    }
}
