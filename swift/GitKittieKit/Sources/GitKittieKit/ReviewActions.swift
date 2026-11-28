import Foundation
import Yams

// Actions on decision (ReviewSpec § 2), mirroring `review-actions.ts` in
// `@gitkittie/gitkanban-core`: what happens to cards when a request, an item or a browser
// check is accepted, gets changes requested, or is rejected, and the `actions_run` record of
// what the app did.
//
//     on_accept:  { to: testing }                      # move defaults to the request's card
//     on_changes: { to: in-progress, comment: true, assign: claude }
//     on_reject:  [{ to: todo }, { move: PROJ-9, to: todo }]

/// What a request (or one entry) came to: the outcome its actions are chosen by.
public enum ReviewOutcome: String, CaseIterable, Sendable, Codable {
    case accept, changes, reject

    /// The frontmatter key holding this outcome's actions.
    public var key: String {
        switch self {
        case .accept: return "on_accept"
        case .changes: return "on_changes"
        case .reject: return "on_reject"
        }
    }

    /// The outcome one decision means for that entry's own actions; `nil` for pending.
    public init?(status: ReviewStatus) {
        switch status {
        case .approved: self = .accept
        case .changesRequested: self = .changes
        case .rejected: self = .reject
        case .pending: return nil
        }
    }

    /// "accepted", "asked for changes in", "rejected": for the card's activity line.
    public var verb: String {
        switch self {
        case .accept: return "accepted"
        case .changes: return "asked for changes in"
        case .reject: return "rejected"
        }
    }

    public var title: String {
        switch self {
        case .accept: return "Accepted"
        case .changes: return "Changes requested"
        case .reject: return "Rejected"
        }
    }
}

/// One thing to do to a card.
public struct ReviewAction: Equatable, Sendable, Hashable, Codable {
    /// Card id on the same board; `nil` = the request's `card` (request level only).
    public var move: String?
    /// Lane: id, status or name.
    public var to: String
    /// Copy the deciding comments into the card's activity log.
    public var comment: Bool
    /// Set the card's `assignee` to this board user.
    public var assign: String?

    public init(move: String? = nil, to: String, comment: Bool = false, assign: String? = nil) {
        self.move = move; self.to = to; self.comment = comment; self.assign = assign
    }
}

/// The actions of a request, item or check, per outcome.
public struct ReviewActions: Equatable, Sendable, Hashable, Codable {
    public var accept: [ReviewAction] = []
    public var changes: [ReviewAction] = []
    public var reject: [ReviewAction] = []

    public init(accept: [ReviewAction] = [], changes: [ReviewAction] = [], reject: [ReviewAction] = []) {
        self.accept = accept; self.changes = changes; self.reject = reject
    }

    public subscript(outcome: ReviewOutcome) -> [ReviewAction] {
        get {
            switch outcome {
            case .accept: return accept
            case .changes: return changes
            case .reject: return reject
            }
        }
        set {
            switch outcome {
            case .accept: accept = newValue
            case .changes: changes = newValue
            case .reject: reject = newValue
            }
        }
    }

    public var isEmpty: Bool { accept.isEmpty && changes.isEmpty && reject.isEmpty }
}

/// What an action run came to.
public enum ActionRunResult: String, CaseIterable, Sendable, Codable {
    case moved, already, skipped, undone
}

/// One action the app ran (or skipped), as the request's `actions_run` records it.
public struct ActionRun: Equatable, Sendable, Hashable, Codable {
    public var on: ReviewOutcome
    /// `nil` for the request; an item or check id otherwise.
    public var entry: String?
    public var card: String
    /// The lane id the card was in.
    public var from: String?
    public var to: String
    public var result: ActionRunResult
    /// Why it was skipped.
    public var reason: String?
    public var by: String
    public var at: String
    public var undoneAt: String?
    /// The card's fields the action changed, as they were before (`nil` = null): what Undo restores.
    public var before: [String: String?]

    public init(on: ReviewOutcome, entry: String? = nil, card: String, from: String? = nil, to: String,
                result: ActionRunResult, reason: String? = nil, by: String, at: String, undoneAt: String? = nil,
                before: [String: String?] = [:]) {
        self.on = on; self.entry = entry; self.card = card; self.from = from; self.to = to
        self.result = result; self.reason = reason; self.by = by; self.at = at; self.undoneAt = undoneAt
        self.before = before
    }

    public var isUndone: Bool { undoneAt != nil }
}

extension Review {
    static func parseActionList(_ node: Node?) -> [ReviewAction] {
        guard let node else { return [] }
        let entries: [Node] = node.sequence.map(Array.init) ?? [node]
        return entries.compactMap { entry in
            guard let map = entry.mapping, let to = string(map["to"]) else { return nil }
            return ReviewAction(move: string(map["move"]), to: to, comment: bool(map["comment"]), assign: string(map["assign"]))
        }
    }

    static func parseActions(_ map: Node.Mapping?) -> ReviewActions {
        ReviewActions(accept: parseActionList(map?["on_accept"]), changes: parseActionList(map?["on_changes"]),
                      reject: parseActionList(map?["on_reject"]))
    }

    static func parseActionsRun(_ node: Node?) -> [ActionRun] {
        (node?.sequence.map(Array.init) ?? []).compactMap { entry in
            guard let map = entry.mapping, let on = string(map["on"]).flatMap(ReviewOutcome.init(rawValue:)),
                  let card = string(map["card"]), let to = string(map["to"]) else { return nil }
            var before: [String: String?] = [:]
            for (key, value) in map["before"]?.mapping ?? [:] {
                guard let name = key.string else { continue }
                before[name] = string(value)
            }
            return ActionRun(on: on, entry: string(map["entry"]), card: card, from: string(map["from"]), to: to,
                             result: string(map["result"]).flatMap(ActionRunResult.init(rawValue:)) ?? .moved,
                             reason: string(map["reason"]), by: string(map["by"]) ?? "unknown", at: string(map["at"]) ?? "",
                             undoneAt: string(map["undone_at"]), before: before)
        }
    }

    /// Actions as written by the app: one action as a mapping, several as a list.
    static func node(_ actions: [ReviewAction]) -> Node? {
        let nodes = actions.map { action -> Node in
            var pairs: [(Node, Node)] = []
            if let move = action.move, !move.isEmpty { pairs.append((scalar("move"), scalar(move))) }
            pairs.append((scalar("to"), scalar(action.to)))
            if action.comment { pairs.append((scalar("comment"), Node("true", Tag(.bool)))) }
            if let assign = action.assign, !assign.isEmpty { pairs.append((scalar("assign"), scalar(assign))) }
            return .mapping(Node.Mapping(pairs, Tag(.map), .flow))
        }
        switch nodes.count {
        case 0: return nil
        case 1: return nodes[0]
        default: return .sequence(Node.Sequence(nodes))
        }
    }

    static func addActions(_ actions: ReviewActions, to pairs: inout [(Node, Node)]) {
        for outcome in ReviewOutcome.allCases {
            if let value = node(actions[outcome]) { pairs.append((scalar(outcome.key), value)) }
        }
    }

    static func node(_ run: ActionRun) -> Node {
        func optional(_ value: String?) -> Node { value.map(scalar) ?? null }
        var pairs: [(Node, Node)] = [
            (scalar("on"), scalar(run.on.rawValue)),
            (scalar("entry"), optional(run.entry)),
            (scalar("card"), scalar(run.card)),
            (scalar("from"), optional(run.from)),
            (scalar("to"), scalar(run.to)),
            (scalar("result"), scalar(run.result.rawValue)),
            (scalar("reason"), optional(run.reason)),
            (scalar("by"), scalar(run.by)),
            (scalar("at"), scalar(run.at)),
            (scalar("undone_at"), optional(run.undoneAt)),
        ]
        if !run.before.isEmpty {
            let entries = run.before.keys.sorted().map { key in (scalar(key), optional(run.before[key] ?? nil)) }
            pairs.append((scalar("before"), .mapping(Node.Mapping(entries, Tag(.map), .flow))))
        }
        return .mapping(Node.Mapping(pairs))
    }

    // MARK: Writes

    /// Append one entry to the request's `actions_run`. Existing entries are never rewritten.
    public static func appendActionRun(_ text: String, _ run: ActionRun) throws -> String {
        try mutateFrontmatter(text) { map in
            let list = map["actions_run"]?.sequence.map(Array.init) ?? []
            map["actions_run"] = .sequence(Node.Sequence(list + [node(run)]))
        }
    }

    /// Mark the `index`-th `actions_run` entry undone: `undone_at`, nothing else.
    public static func markActionRunUndone(_ text: String, index: Int, at: Date = Date()) throws -> String {
        let stamp = timestamp(at)
        return try mutateFrontmatter(text) { map in
            guard var list = map["actions_run"]?.sequence.map(Array.init), list.indices.contains(index),
                  var entry = list[index].mapping else { throw ReviewError.actionRunNotFound(index) }
            entry["undone_at"] = scalar(stamp)
            list[index] = .mapping(entry)
            map["actions_run"] = .sequence(Node.Sequence(list))
        }
    }
}
