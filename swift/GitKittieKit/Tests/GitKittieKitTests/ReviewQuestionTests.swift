import Foundation
import Testing
@testable import GitKittieKit

private let questionsText = """
---
config: review
id: GKM-001-mail-decisions
card: GKM-001
title: Four decisions
requested_at: 2026-11-24T11:12:49Z
agent_only_key: keep me
items:
  - id: logo
    file: logo.png
    status: pending
    comments: []
questions:
  - id: providers
    question: Which mail providers at first release?
    detail: |
      **Gmail** needs Google's verification.

      Pick the smallest useful set.
    select: one
    other: true
    agent_note: untouched
    options:
      - id: icloud
        label: iCloud only
        detail: "Smallest scope. Only useful to iCloud users at first."
      - id: imap
        label: iCloud and IMAP
      - id: gmail
        label: Include Gmail
    answer: []
    answer_other:
    answered_by:
    answered_at:
    comments: []
    handled_at:
  - id: platforms
    question: Where should it run?
    select: many
    options:
      - mac
      - id: ios
        label: iPhone and iPad
    answer: [mac, ios, nope]
    answered_by: sil
    answered_at: 2026-11-24T12:00:00Z
---

Notes for Sil.
"""

private let at = ISO8601DateFormatter().date(from: "2026-11-24T13:00:00Z")!

@Suite struct ReviewQuestionTests {
    @Test func parsesQuestions() {
        let r = Review.parse(questionsText, folder: "GitKittie/review/GKM-001-mail-decisions")
        #expect(r.questions.map(\.id) == ["providers", "platforms"])
        let providers = r.questions[0]
        #expect(providers.question == "Which mail providers at first release?")
        #expect(providers.detail?.contains("**Gmail**") == true && providers.detail?.contains("\n\nPick") == true)
        #expect(providers.select == .one && providers.allowsOther)
        #expect(providers.options.map(\.id) == ["icloud", "imap", "gmail"])
        #expect(providers.options[0].detail == "Smallest scope. Only useful to iCloud users at first.")
        #expect(providers.options[1].detail == nil)
        #expect(!providers.isAnswered && providers.answer.isEmpty && providers.answerOther == nil)

        let platforms = r.questions[1]
        #expect(platforms.select == .many && !platforms.allowsOther)
        // A bare option is its own label; an answer id that is no option is not read.
        #expect(platforms.options == [ReviewQuestionOption(id: "mac", label: "mac"), ReviewQuestionOption(id: "ios", label: "iPhone and iPad")])
        #expect(platforms.answer == ["mac", "ios"] && platforms.isAnswered && platforms.awaitingAgent)
        #expect(platforms.answerText == "mac, iPhone and iPad")

        let s = r.summary
        #expect(s.total == 3 && s.items == 1 && s.questions == 2 && s.answered == 1)
        #expect(s.pending == 2 && s.pendingItems == 1 && s.unanswered == 1 && s.awaitingAgent == 1)
        #expect(s.waitingDescription == "1 item and 1 question")
        #expect(s.questionsDescription == "2 questions, 1 answered")
    }

    @Test func singleChoiceIsEnforced() throws {
        #expect(throws: ReviewError.oneChoiceOnly) {
            try Review.applyAnswer(questionsText, questionID: "providers", choices: ["icloud", "imap"], other: nil, by: "sil", at: at)
        }
        #expect(throws: ReviewError.oneChoiceOnly) {
            try Review.applyAnswer(questionsText, questionID: "providers", choices: ["icloud"], other: "Fastmail", by: "sil", at: at)
        }
        #expect(throws: ReviewError.unknownOption("outlook")) {
            try Review.applyAnswer(questionsText, questionID: "providers", choices: ["outlook"], other: nil, by: "sil", at: at)
        }
        #expect(throws: ReviewError.emptyAnswer) {
            try Review.applyAnswer(questionsText, questionID: "providers", choices: [], other: "  ", by: "sil", at: at)
        }
        #expect(throws: ReviewError.questionNotFound("nope")) {
            try Review.applyAnswer(questionsText, questionID: "nope", choices: ["icloud"], other: nil, by: "sil", at: at)
        }
        // A hand-written file with two answers to a one-choice question reads as the first one.
        let twice = questionsText.replacingOccurrences(of: "    answer: []\n    answer_other:", with: "    answer: [imap, icloud]\n    answer_other:")
        #expect(Review.parse(twice, folder: "f").questions[0].answer == ["imap"])
    }

    @Test func answersOneAndKeepsTheRestIntact() throws {
        let next = try Review.applyAnswer(questionsText, questionID: "providers", choices: ["imap"], other: nil,
                                          comment: "Gmail after launch.", by: "sil", at: at)
        let before = Review.parse(questionsText, folder: "f"), after = Review.parse(next, folder: "f")
        let q = after.questions[0]
        #expect(q.answer == ["imap"] && q.answerOther == nil)
        #expect(q.answeredBy == "sil" && q.answeredAt == "2026-11-24T13:00:00Z")
        #expect(q.comments.map(\.text) == ["Gmail after launch."])
        #expect(q.options == before.questions[0].options && q.detail == before.questions[0].detail)
        #expect(after.questions[1] == before.questions[1])
        #expect(after.items == before.items)
        #expect(next.contains("agent_only_key: keep me") && next.contains("agent_note: untouched"))
        #expect(next.hasSuffix("Notes for Sil.\n") || next.hasSuffix("Notes for Sil."))
        #expect(next.range(of: "items:")!.lowerBound < next.range(of: "questions:")!.lowerBound)
        #expect(after.summary.pending == 1 && after.summary.awaitingAgent == 2)
    }

    @Test func answersManyAndOther() throws {
        let many = try Review.applyAnswer(questionsText, questionID: "platforms", choices: ["ios", "mac"], other: nil, by: "sil", at: at)
        // Written in option order, whatever order they were chosen in.
        #expect(Review.parse(many, folder: "f").questions[1].answer == ["mac", "ios"])
        #expect(throws: ReviewError.otherNotAllowed) {
            try Review.applyAnswer(questionsText, questionID: "platforms", choices: ["mac"], other: "Web", by: "sil", at: at)
        }
        let own = try Review.applyAnswer(questionsText, questionID: "providers", choices: [], other: " Fastmail first ", by: "sil", at: at)
        let q = Review.parse(own, folder: "f").questions[0]
        #expect(q.answer.isEmpty && q.answerOther == "Fastmail first" && q.isAnswered)
        #expect(q.answerText == "Fastmail first")
    }

    @Test func answerCanChangeUntilHandled() throws {
        let first = try Review.applyAnswer(questionsText, questionID: "providers", choices: [], other: "Fastmail", by: "sil", at: at)
        let changed = try Review.applyAnswer(first, questionID: "providers", choices: ["gmail"], other: nil, by: "sil", at: at)
        let q = Review.parse(changed, folder: "f").questions[0]
        #expect(q.answer == ["gmail"] && q.answerOther == nil)

        let handled = try Review.markQuestionHandled(changed, questionID: "providers", at: at)
        let h = Review.parse(handled, folder: "f").questions[0]
        #expect(h.handledAt == "2026-11-24T13:00:00Z" && !h.awaitingAgent && h.answer == ["gmail"])
        #expect(throws: ReviewError.alreadyHandled("providers")) {
            try Review.applyAnswer(handled, questionID: "providers", choices: ["icloud"], other: nil, by: "sil", at: at)
        }
        let commented = try Review.appendQuestionComment(handled, questionID: "providers", by: "sil", body: "Thanks")
        #expect(Review.parse(commented, folder: "f").questions[0].comments.map(\.text) == ["Thanks"])
    }

    @Test func rendersAndAppendsQuestions() throws {
        let question = Review.NewQuestion(
            id: "fit", question: "How does Mail fit GitKittie?", detail: "Line one.\n\nLine **two**.", select: .one, allowsOther: true,
            options: [ReviewQuestionOption(id: "git-optional", label: "Git optional", detail: "Closest to a normal mail client."),
                      ReviewQuestionOption(id: "git-first", label: "Git first")])
        let text = try Review.render(id: "GKM-001-q", project: "GitKittie", card: "GKM-001", title: "Decisions", question: nil,
                                     requestedBy: "claude", at: at, notes: "Why.", items: [], questions: [question])
        #expect(!text.contains("items:"))
        let r = Review.parse(text, folder: "f")
        #expect(r.items.isEmpty && r.questions.count == 1)
        let q = r.questions[0]
        #expect(q.id == "fit" && q.select == .one && q.allowsOther && q.detail == "Line one.\n\nLine **two**.")
        #expect(q.options.map(\.label) == ["Git optional", "Git first"] && q.options[0].detail == "Closest to a normal mail client.")
        #expect(!q.isAnswered && r.summary.pending == 1 && r.summary.questionsDescription == "1 question")
        #expect(text.contains("other: true") && text.contains("answer: []") && text.contains("handled_at: null"))
        // Multi-line Markdown is written as a block, as a person would write it.
        #expect(text.contains("detail: |-\n    Line one.\n\n    Line **two**."))

        let more = try Review.appendItems(text, [Review.NewItem(id: "logo", file: "logo.png")],
                                          questions: [Review.NewQuestion(id: "name", question: "Name?", select: .many,
                                                                          options: [ReviewQuestionOption(id: "a", label: "A")])])
        let m = Review.parse(more, folder: "f")
        #expect(m.items.map(\.id) == ["logo"] && m.questions.map(\.id) == ["fit", "name"] && m.questions[1].select == .many)
        #expect(m.questions[0] == q)
        #expect(more.hasSuffix("Why.\n"))
    }

    @Test func requestWithoutQuestionsIsUnchanged() throws {
        let old = """
        ---
        config: review
        id: OLD
        items:
          - id: a
            file: a.png
            status: pending
        ---
        """
        let r = Review.parse(old, folder: "f")
        #expect(r.questions.isEmpty)
        #expect(r.summary == ReviewSummary(total: 1, pending: 1, approved: 0, rejected: 0, changesRequested: 0, awaitingAgent: 0))
        #expect(r.summary.questionsDescription == nil && r.summary.waitingDescription == "1 item")
        let decided = try Review.applyDecision(old, itemID: "a", status: .approved, by: "sil", at: at)
        #expect(!decided.contains("questions"))
        let rendered = try Review.render(id: "x", project: nil, card: nil, title: "x", question: nil, requestedBy: "a", at: at,
                                         notes: nil, items: [Review.NewItem(id: "a", file: "a.png")])
        #expect(rendered.contains("items:") && !rendered.contains("questions"))
    }
}

