import XCTest
@testable import GitKittieKit

final class CardActivityTests: XCTestCase {
    private let card = """
    ---
    id: T-1
    title: A task
    status: todo
    tags:
      - ios
      - "app store"
    due: 2026-11-24
    created_at: 2026-11-10T08:00:00Z
    custom: kept
    ---

    ## Context

    Some text.

    ## Activity log

    - 2026-11-20T10:00:00Z — `claude` created the card.
    - 2026-11-22 claude: moved it on,
      over two lines.
    - no date here
    """

    func testReadsLabelsDueAndCreated() {
        let parsed = BoardStore.parseCard(text: card, fileName: "T-1.md", fieldSource: nil)
        XCTAssertEqual(parsed.fields.tags, ["ios", "app store"])
        XCTAssertEqual(parsed.fields.due, "2026-11-24")
        XCTAssertEqual(parsed.fields.createdAt.map { String($0.prefix(10)) }, "2026-11-10")
    }

    func testReadsInlineLabels() {
        let text = "---\nid: T-2\ntitle: x\nstatus: todo\ntags: [ios, bug]\n---\n\nBody\n"
        XCTAssertEqual(BoardStore.parseCard(text: text, fileName: "T-2.md", fieldSource: nil).fields.tags, ["ios", "bug"])
    }

    func testWritingLabelsKeepsEverythingElse() {
        let updated = CardText.update(card, set: ["due": "2026-12-01"], lists: ["tags": ["bug", "app store"]])
        XCTAssertTrue(updated.contains("tags: [bug, \"app store\"]"))
        XCTAssertFalse(updated.contains("  - ios"))
        XCTAssertTrue(updated.contains("custom: kept"))
        XCTAssertTrue(updated.contains("- no date here"))
        let parsed = BoardStore.parseCard(text: updated, fileName: "T-1.md", fieldSource: nil)
        XCTAssertEqual(parsed.fields.tags, ["bug", "app store"])
        XCTAssertEqual(parsed.fields.due, "2026-12-01")
        // No labels left: the key stays, empty.
        XCTAssertTrue(CardText.update(card, set: [:], lists: ["tags": []]).contains("tags: []"))
    }

    func testEntries() {
        let body = BoardMarkdown.splitFrontmatter(card).1
        let entries = CardActivity.entries(in: body)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].author, "claude")
        XCTAssertEqual(entries[0].text, "created the card.")
        XCTAssertNotNil(entries[0].date)
        XCTAssertEqual(entries[1].author, "claude")
        XCTAssertEqual(entries[1].text, "moved it on, over two lines.")
        XCTAssertNil(entries[2].stamp)
        XCTAssertEqual(entries[2].text, "no date here")
        XCTAssertEqual(CardActivity.count(in: body), 3)
        XCTAssertEqual(CardActivity.count(in: "No log"), 0)
    }

    func testSplitAndJoinGiveTheSameText() {
        let body = BoardMarkdown.splitFrontmatter(card).1.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = CardActivity.split(body)
        XCTAssertTrue(parts.notes.hasSuffix("Some text."))
        XCTAssertTrue(parts.log.hasPrefix("## Activity log"))
        XCTAssertEqual(CardActivity.join(notes: parts.notes, log: parts.log), body)
        // A log that is not the last section is left where it is.
        let middle = "## Activity log\n\n- one\n\n## After\n\ntext"
        XCTAssertEqual(CardActivity.split(middle).log, "")
    }
}
