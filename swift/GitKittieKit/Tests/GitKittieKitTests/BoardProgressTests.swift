import Testing
@testable import GitKittieKit

struct BoardProgressTests {
    private let lanes = [
        Lane(id: "todo", name: "To do", folder: "1. To do", status: "todo"),
        Lane(id: "in-progress", name: "In Progress", folder: "2. In Progress", status: "in_progress"),
        Lane(id: "in-review", name: "In Review", folder: "3. In Review", status: "in_review"),
        Lane(id: "done", name: "Done", folder: "5. Done", status: "done", terminal: true),
    ]

    private func card(_ id: String, updated: String? = nil, read: String? = nil) -> Card {
        Card(fields: CardFields(id: id, title: id, updatedAt: updated, readAt: read), body: "")
    }

    @Test func splitsAroundTheProgressLane() {
        #expect(lanes.map { BoardProgress.stage(for: $0, in: lanes) } == [.pipeline, .working, .checkedOff, .checkedOff])
        let custom = [Lane(id: "idea", name: "Ideas", folder: "a", status: "idea"),
                      Lane(id: "draft", name: "Drafting", folder: "b", status: "draft"),
                      Lane(id: "shipped", name: "Shipped", folder: "c", status: "shipped")]
        #expect(custom.map { BoardProgress.stage(for: $0, in: custom) } == [.pipeline, .working, .checkedOff])
    }

    @Test func unreadUntilReadAndAgainAfterAnUpdate() {
        #expect(BoardProgress.isUnread(card("a").fields))
        #expect(!BoardProgress.isUnread(card("a", updated: "2026-11-08T09:00:00Z", read: "2026-11-08T10:00:00Z").fields))
        #expect(!BoardProgress.isUnread(card("a", read: "2026-11-08T10:00:00Z").fields))
        #expect(BoardProgress.isUnread(card("a", updated: "2026-11-08T11:00:00.500Z", read: "2026-11-08T10:00:00Z").fields))
    }

    @Test func groupsPutUnreadFirstThenNewest() {
        let columns = [
            Column(lane: lanes[0], cards: [card("next")]),
            Column(lane: lanes[1], cards: [card("doing")]),
            Column(lane: lanes[2], cards: [card("old-read", updated: "2026-11-01T00:00:00Z", read: "2026-11-02T00:00:00Z"),
                                           card("older-unread", updated: "2026-11-03T00:00:00Z")]),
            Column(lane: lanes[3], cards: [card("new-unread", updated: "2026-11-05T00:00:00Z")]),
        ]
        let groups = BoardProgress.groups(columns)
        #expect(groups.map(\.stage) == [.working, .pipeline, .checkedOff])
        #expect(groups[0].entries.map(\.card.id) == ["doing"])
        #expect(groups[2].entries.map(\.card.id) == ["new-unread", "older-unread", "old-read"])
        #expect(groups[2].entries[0].lane.id == "done")
    }

    @Test func latestActivityIsTheLastLogEntry() {
        let body = "# T\n\n## Activity log\n\n- one\n- two `claude`\n\n## Notes\n- not this\n"
        #expect(BoardProgress.latestActivity(body) == "two `claude`")
        #expect(BoardProgress.latestActivity("# T\nnothing") == nil)
    }

    @Test func parsesReadAndUpdatedFromFrontmatter() {
        let text = "---\nid: A-1\ntitle: A\nupdated_at: 2026-11-08T10:00:00Z\nread_at: \"2026-11-08T11:00:00Z\"\nread_by: sil\n---\n# A\n"
        let parsed = BoardStore.parseCard(text: text, fieldSource: nil)
        #expect(parsed.fields.updatedAt == "2026-11-08T10:00:00Z")
        #expect(parsed.fields.readAt == "2026-11-08T11:00:00Z")
        #expect(parsed.fields.readBy == "sil")
    }
}
