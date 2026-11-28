import Foundation
import Testing
@testable import GitKittieKit

// The shared review vectors (packages/gitkanban-core/tests/vectors/review): each `<name>.md`
// is a request and `<name>.json` what both parsers read from it. The TypeScript side checks the
// same files in review-vectors.test.ts, so the two parsers cannot drift apart.

private let vectorFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("packages/gitkanban-core/tests/vectors/review")

private func optional(_ value: Any?) -> Any { value ?? NSNull() }

private func actions(_ actions: ReviewActions) -> [String: Any] {
    func list(_ list: [ReviewAction]) -> [[String: Any]] {
        list.map { ["move": optional($0.move), "to": $0.to, "comment": $0.comment, "assign": optional($0.assign)] }
    }
    return ["accept": list(actions.accept), "changes": list(actions.changes), "reject": list(actions.reject)]
}

/// The same shape as `normalizeReview` in tests/vectors/normalize.ts.
func normalizedReview(_ review: ReviewRequest) -> [String: Any] {
    let summary = review.summary
    return [
        "id": review.id,
        "title": review.title,
        "card": optional(review.card),
        "notify": review.notify.rawValue,
        "for": review.assignedTo,
        "due": optional(review.due),
        "actions": actions(review.actions),
        "items": review.items.map { ["id": $0.id, "status": $0.status.rawValue, "actions": actions($0.actions)] as [String: Any] },
        "questions": review.questions.map { ["id": $0.id, "answered": $0.isAnswered] as [String: Any] },
        "checks": review.checks.map { check -> [String: Any] in
            [
                "id": check.id, "url": check.url, "title": optional(check.title), "note": optional(check.note),
                "sizes": check.sizes.map { ["id": $0.id, "label": $0.label, "width": optional($0.width), "height": optional($0.height), "ua": $0.ua.rawValue] as [String: Any] },
                "appearance": check.appearance.map(\.rawValue),
                "checklist": check.checklist.map { ["id": $0.id, "text": $0.text] },
                "result_keys": check.resultKeys,
                "results": check.results.mapValues { result -> [String: Any] in
                    [
                        "viewport": optional(result.viewport), "by": optional(result.by), "at": optional(result.at),
                        "screenshot": optional(result.screenshot),
                        "answers": result.answers.mapValues { ["result": $0.result.rawValue, "note": optional($0.note), "at": optional($0.at)] as [String: Any] },
                    ]
                },
                "status": check.status.rawValue, "decided_by": optional(check.decidedBy), "decided_at": optional(check.decidedAt),
                "revises": optional(check.revises), "comments": check.comments.count, "actions": actions(check.actions),
                "failed": check.failures.map {
                    ["size": $0.size, "item": $0.item, "text": $0.text, "result": $0.result.rawValue, "note": optional($0.note),
                     "screenshot": optional($0.screenshot)] as [String: Any]
                },
            ]
        },
        "actions_run": review.actionsRun.map { run -> [String: Any] in
            [
                "on": run.on.rawValue, "entry": optional(run.entry), "card": run.card, "from": optional(run.from), "to": run.to,
                "result": run.result.rawValue, "reason": optional(run.reason), "by": run.by, "at": run.at,
                "undone_at": optional(run.undoneAt), "before": run.before.mapValues { optional($0) },
            ]
        },
        "outcome": optional(review.outcome?.rawValue),
        "waiting": review.waitingEntries,
        "waiting_for": ["sil": review.waitingEntries(forUser: "sil"), "herma": review.waitingEntries(forUser: "herma"),
                        "nobody": review.waitingEntries(forUser: nil)],
        "summary": [
            "total": summary.total, "pending": summary.pending, "approved": summary.approved, "rejected": summary.rejected,
            "changes_requested": summary.changesRequested, "awaiting_agent": summary.awaitingAgent,
            "questions": summary.questions, "answered": summary.answered, "checks": summary.checks,
        ],
    ]
}

@Suite struct ReviewVectorTests {
    static let names: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: vectorFolder.path)) ?? [])
        .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()

    @Test func thereAreVectors() { #expect(Self.names.count >= 6) }

    @Test(arguments: names) func parsesLikeTheTypeScript(_ name: String) throws {
        let text = try String(contentsOf: vectorFolder.appendingPathComponent("\(name).md"), encoding: .utf8)
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: vectorFolder.appendingPathComponent("\(name).json"))) as! NSDictionary
        let actual = normalizedReview(Review.parse(text, folder: "Pets/review/\(name)"))
        // Through JSON, so numbers and nulls compare the way the TypeScript wrote them.
        let roundTripped = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: actual)) as! NSDictionary
        for key in expected.allKeys as! [String] {
            #expect(roundTripped[key] as? NSObject == expected[key] as? NSObject, "\(name): \(key)\nswift: \(String(describing: roundTripped[key]))\nts:    \(String(describing: expected[key]))")
        }
        #expect(Set(roundTripped.allKeys as! [String]) == Set(expected.allKeys as! [String]))
    }
}
