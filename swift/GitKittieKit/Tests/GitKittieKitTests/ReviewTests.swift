import Foundation
import Testing
@testable import GitKittieKit

private let reviewText = """
---
config: review
id: MORROW-182-pet-models
card: MORROW-182
title: Pet models, round 1
question: Pick one dog.
requested_at: 2026-11-08T14:00:00Z
agent_only_key: keep me
items:
  - id: dog-v1
    file: dog-v1.usdz
    preview: dog-v1.png
    kind: model
    group: dog
    pick: one
    note: 2600 faces
    status: pending
    decided_by:
    comments: []
  - id: dog-v2
    file: dog-v2.usdz
    group: dog
    status: approved
    decided_by: sil
    comments:
      - by: sil
        at: 2026-11-08T15:00:00Z
        text: "Ears: right now"
  - id: bark
    file: sounds/bark.m4a
    status: rejected
    handled_at: 2026-11-08T16:00:00Z
  - id: walk
    file: walk.png
    kind: animation
    frames: 8
    fps: 12
---

Made with Tripo.
"""

@Suite struct ReviewTests {
    @Test func onlyWaitingHidesDecidedItemsButKeepsAnOpenGroupTogether() {
        var r = Review.parse(reviewText, folder: "Morrow/review/MORROW-182-pet-models")
        // dog-v2 is decided but dog-v1, in the same group, still waits: both stay.
        #expect(r.isStillOpen(r.items[1]))
        #expect(!r.isStillOpen(r.items[2]))
        #expect(r.settledIDs.items == ["bark"])
        #expect(r.settledIDs.questions.isEmpty)

        // Once the group is decided its options are settled too.
        r.items[0].status = .rejected
        #expect(r.settledIDs.items == ["dog-v1", "dog-v2", "bark"])

        // Nothing waiting: a finished request shows everything it decided.
        r.items[3].status = .approved
        #expect(r.settledIDs.items.isEmpty)
    }

    @Test func parsesRequestAndItems() {
        let r = Review.parse(reviewText, folder: "Morrow/review/MORROW-182-pet-models")
        #expect(r.id == "MORROW-182-pet-models")
        #expect(r.card == "MORROW-182")
        #expect(r.requestedAt == "2026-11-08T14:00:00Z")
        #expect(r.items.map(\.id) == ["dog-v1", "dog-v2", "bark", "walk"])
        #expect(r.items[0].kind == .model && r.items[0].pickOne && r.items[0].decidedBy == nil)
        #expect(r.items[1].comments == [ReviewComment(by: "sil", at: "2026-11-08T15:00:00Z", text: "Ears: right now")])
        #expect(r.items[2].kind == .audio)
        #expect(r.items[3].frames == 8 && r.items[3].fps == 12)
        #expect(r.body.trimmingCharacters(in: .whitespacesAndNewlines) == "Made with Tripo.")
        #expect(r.summary == ReviewSummary(total: 4, pending: 2, approved: 1, rejected: 1, changesRequested: 0, awaitingAgent: 1))
        #expect(r.groups.map(\.id) == ["group:dog", "item:bark", "item:walk"])
        #expect(r.assetPath("../../art/x.png") == "Morrow/art/x.png")
    }

    @Test func decisionChangesOnlyReviewerFields() throws {
        let at = ISO8601DateFormatter().date(from: "2026-11-08T17:00:00Z")!
        let next = try Review.applyDecision(reviewText, itemID: "dog-v1", status: .changesRequested, by: "sil", at: at)
        let before = Review.parse(reviewText, folder: "f"), after = Review.parse(next, folder: "f")
        #expect(after.items[0].status == .changesRequested)
        #expect(after.items[0].decidedBy == "sil" && after.items[0].decidedAt == "2026-11-08T17:00:00Z")
        #expect(after.items[0].note == "2600 faces" && after.items[0].preview == "dog-v1.png")
        #expect(Array(after.items.dropFirst()) == Array(before.items.dropFirst()))
        #expect(next.contains("agent_only_key: keep me"))
        #expect(next.hasSuffix("Made with Tripo.\n") || next.hasSuffix("Made with Tripo."))
        // Key order is preserved.
        #expect(next.range(of: "config:")!.lowerBound < next.range(of: "items:")!.lowerBound)

        let cleared = try Review.applyDecision(next, itemID: "dog-v1", status: .pending, by: "sil")
        let c = Review.parse(cleared, folder: "f").items[0]
        #expect(c.status == .pending && c.decidedBy == nil && c.decidedAt == nil)
    }

    @Test func commentsAppendOnly() throws {
        let next = try Review.appendComment(reviewText, itemID: "dog-v2", by: "sil", body: "  Tail: too long  ")
        #expect(Review.parse(next, folder: "f").items[1].comments.map(\.text) == ["Ears: right now", "Tail: too long"])
        let first = try Review.appendComment(reviewText, itemID: "dog-v1", by: "sil", body: "true")
        #expect(Review.parse(first, folder: "f").items[0].comments.map(\.text) == ["true"])
        #expect(throws: ReviewError.emptyComment) { try Review.appendComment(reviewText, itemID: "dog-v2", by: "s", body: " ") }
        #expect(throws: ReviewError.itemNotFound("nope")) { try Review.applyDecision(reviewText, itemID: "nope", status: .approved, by: "s") }
    }

    @Test func resolvesReviewPath() {
        #expect(Review.resolveReviewPath("../../{folder}/review", projectFolder: "Tasks/Morrow") == "Morrow/review")
        #expect(Review.resolveReviewPath("review", projectFolder: "Tasks/Morrow") == "Tasks/Morrow/review")
        #expect(Review.resolveReviewPath(nil, projectFolder: "Tasks/Morrow") == nil)
        #expect(Review.resolveReviewPath("../../../x", projectFolder: "Tasks/Morrow") == nil)
        #expect(Review.resolveReviewPath("/abs", projectFolder: "Tasks/Morrow") == nil)
    }

    @Test func parsesAndInheritsReviewPathConfig() throws {
        let root = try BoardStore.parseBoardConfig(yaml: "config: board\nreview_path: \"../../{folder}/review\"\n")
        #expect(root.reviewPath == "../../{folder}/review")
        #expect(resolveEffectiveConfig(root, ProjectConfig()).reviewPath == "../../{folder}/review")
        let project = try BoardStore.parseProjectConfig(yaml: "project: X\nreview_path: review\n")
        #expect(resolveEffectiveConfig(root, project).reviewPath == "review")
    }
}
