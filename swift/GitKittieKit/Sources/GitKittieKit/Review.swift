import Foundation
import Yams

// Review requests — the asset-review contract from `project-assets/Agents/review-workflow.md`.
// Mirrors `@gitkittie/gitkanban-core`'s `review.ts` (the TypeScript is the source of truth):
// parse a `review.md`, record a reviewer decision, append a comment, and resolve where a
// project's review requests live (`review_path`). Writes go through Yams' ordered `Node`
// tree, so key order, unknown keys and the agent's fields round-trip with their values intact.

public enum ReviewStatus: String, CaseIterable, Sendable, Codable {
    case pending
    case approved
    case rejected
    case changesRequested = "changes-requested"

    public var title: String {
        switch self {
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        case .changesRequested: return "Changes requested"
        }
    }
}

public enum ReviewKind: String, CaseIterable, Sendable, Codable {
    case image, model, audio, animation, video, other

    /// Infer a kind from a file extension, for items that omit `kind`.
    public static func forFile(_ file: String) -> ReviewKind {
        let ext = (file as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "webp", "svg", "heic": return .image
        case "usdz", "glb", "gltf", "reality": return .model
        case "m4a", "wav", "mp3", "aiff", "aif", "caf": return .audio
        case "gif": return .animation
        case "mp4", "mov", "m4v": return .video
        default: return .other
        }
    }
}

public struct ReviewComment: Equatable, Sendable, Hashable {
    public var by: String
    public var at: String
    public var text: String
    /// A marked-up copy of the item the comment is about, relative to the request folder.
    public var image: String?
    public init(by: String, at: String, text: String, image: String? = nil) { self.by = by; self.at = at; self.text = text; self.image = image }
}

public struct ReviewItem: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var file: String
    public var preview: String?
    public var kind: ReviewKind
    public var group: String?
    public var pickOne: Bool
    public var note: String?
    public var revises: String?
    public var status: ReviewStatus
    public var decidedBy: String?
    public var decidedAt: String?
    public var comments: [ReviewComment]
    public var handledAt: String?
    public var shippedTo: String?
    public var frames: Int?
    public var fps: Double?

    /// Decided by the reviewer, not yet acted on by the agent.
    public var awaitingAgent: Bool { status != .pending && handledAt == nil }
}

/// A choice the agent asks the reviewer to make: one of the options (`select: one`) or any
/// of them (`select: many`), optionally with an answer of the reviewer's own (`other`).
public enum QuestionSelect: String, CaseIterable, Sendable, Codable {
    case one, many
}

public struct ReviewQuestionOption: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var label: String
    /// Markdown: what choosing it means, and what it costs.
    public var detail: String?
    public init(id: String, label: String, detail: String? = nil) { self.id = id; self.label = label; self.detail = detail }
}

/// A question in a review request. The agent writes the question and its options; the
/// reviewer writes the answer (`answer`, `answer_other`, `answered_by`, `answered_at`).
public struct ReviewQuestion: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var question: String
    /// Markdown under the question.
    public var detail: String?
    public var select: QuestionSelect
    /// The reviewer may write an answer of their own.
    public var allowsOther: Bool
    public var options: [ReviewQuestionOption]
    /// The chosen options' ids, in option order. At most one for `select: one`.
    public var answer: [String]
    public var answerOther: String?
    public var answeredBy: String?
    public var answeredAt: String?
    public var comments: [ReviewComment]
    public var handledAt: String?

    public var isAnswered: Bool { answeredAt != nil && (!answer.isEmpty || answerOther != nil) }
    /// Answered by the reviewer, not yet acted on by the agent.
    public var awaitingAgent: Bool { isAnswered && handledAt == nil }
    /// The chosen options, in option order.
    public var chosen: [ReviewQuestionOption] { options.filter { answer.contains($0.id) } }
    /// The answer in words: the chosen labels and the reviewer's own answer.
    public var answerText: String? {
        let parts = chosen.map(\.label) + [answerOther].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

public struct ReviewSummary: Equatable, Sendable {
    /// Items and questions.
    public var total = 0
    /// Items without a decision and questions without an answer: what waits for the reviewer.
    public var pending = 0
    public var approved = 0
    public var rejected = 0
    public var changesRequested = 0
    /// Items decided and questions answered that the agent has not acted on yet.
    public var awaitingAgent = 0
    public var questions = 0
    public var answered = 0

    public var items: Int { total - questions }
    public var unanswered: Int { questions - answered }
    /// Items still waiting for a decision (questions left out).
    public var pendingItems: Int { pending - unanswered }

    /// What is waiting, in words: "3 items", "1 question", "2 items and 1 question".
    public var waitingDescription: String { Self.describe(items: pendingItems, questions: unanswered) }

    /// Items and questions in words: "3 items", "1 question", "2 items and 1 question".
    public static func describe(items: Int, questions: Int) -> String {
        let parts = [
            items > 0 ? "\(items) item\(items == 1 ? "" : "s")" : nil,
            questions > 0 ? "\(questions) question\(questions == 1 ? "" : "s")" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: " and ")
    }

    /// The questions in a request list's row: "3 questions, 1 answered"; `nil` without any.
    public var questionsDescription: String? {
        guard questions > 0 else { return nil }
        let count = "\(questions) question\(questions == 1 ? "" : "s")"
        if answered == 0 { return count }
        return answered == questions ? "\(count), \(questions == 1 ? "answered" : "all answered")" : "\(count), \(answered) answered"
    }
}

/// One review request: a folder with a `review.md` and the assets under review.
public struct ReviewRequest: Equatable, Sendable, Identifiable, Hashable {
    /// Source-relative folder of the request (e.g. `Morrow/review/MORROW-182-pet-models`).
    public var folder: String
    public var id: String
    public var project: String?
    public var card: String?
    public var title: String
    public var question: String?
    public var requestedBy: String?
    public var requestedAt: String?
    public var items: [ReviewItem]
    public var questions: [ReviewQuestion] = []
    public var body: String
    /// Which repository or folder the request was loaded from (the app's id for it).
    /// Two sources can hold the same folder path, so a request is told apart by both.
    public var origin: String = ""
    /// Why the request's frontmatter could not be read (invalid YAML), in words; `nil` when
    /// it could. Such a request has no items or questions to show, and says so.
    public var problem: String?

    public var path: String { Review.join(folder, Review.fileName) }
    /// What tells this request apart from every other one the app has loaded.
    public var ref: ReviewRef { ReviewRef(origin: origin, folder: folder) }

    public var summary: ReviewSummary {
        var s = ReviewSummary()
        s.total = items.count
        for item in items {
            switch item.status {
            case .pending: s.pending += 1
            case .approved: s.approved += 1
            case .rejected: s.rejected += 1
            case .changesRequested: s.changesRequested += 1
            }
            if item.awaitingAgent { s.awaitingAgent += 1 }
        }
        s.total += questions.count
        s.questions = questions.count
        for question in questions {
            if question.isAnswered { s.answered += 1 } else { s.pending += 1 }
            if question.awaitingAgent { s.awaitingAgent += 1 }
        }
        return s
    }

    /// Source-relative path of an item's file (or preview), `nil` if it escapes the root.
    public func assetPath(_ file: String) -> String? { Review.joinRelative(folder, file) }

    /// Whether an item still belongs on an "only what's waiting" view: it waits for a decision,
    /// or it is another option of a pick-one group in which something still waits (that choice
    /// is made between all its options, so they stay together). In any other group a decided
    /// file is settled like one on its own: a group of a hundred files with one left shows one.
    public func isStillOpen(_ item: ReviewItem) -> Bool {
        if item.status == .pending { return true }
        guard let group = item.group else { return false }
        let members = items.filter { $0.group == group }
        return members.contains(where: \.pickOne) && members.contains { $0.status == .pending }
    }

    /// The items and questions an "only what's waiting" view hides: decided items outside an
    /// open group, and answered questions. Empty when nothing waits, so a finished request
    /// still shows what was decided.
    public var settledIDs: (items: Set<String>, questions: Set<String>) {
        guard summary.pending > 0 else { return ([], []) }
        return (Set(items.filter { !isStillOpen($0) }.map(\.id)),
                Set(questions.filter(\.isAnswered).map(\.id)))
    }

    /// What a review screen hides for a filter: for `.waiting` what is settled (see
    /// `settledIDs`), for `.answered` what still waits, for `.all` nothing. A screen fixes this
    /// when the request opens or the filter changes, so an entry you just answered stays put.
    public func hiddenIDs(for filter: ReviewFilter) -> (items: Set<String>, questions: Set<String>) {
        switch filter {
        case .all: return ([], [])
        case .waiting: return settledIDs
        case .answered:
            return (Set(items.filter { $0.status == .pending }.map(\.id)),
                    Set(questions.filter { !$0.isAnswered }.map(\.id)))
        }
    }

    /// Every question and item in the order the screens show them: questions first (the agent
    /// waits on them to go on), then the items group by group, as `groups` orders them.
    public var entries: [ReviewEntry] {
        questions.map(ReviewEntry.question) + groups.flatMap { $0.items.map(ReviewEntry.item) }
    }

    /// Items grouped for side-by-side display, in file order. Ungrouped items stand alone.
    public var groups: [ReviewGroup] {
        var result: [ReviewGroup] = []
        var indexByGroup: [String: Int] = [:]
        for item in items {
            if let name = item.group {
                if let index = indexByGroup[name] {
                    result[index].items.append(item)
                } else {
                    indexByGroup[name] = result.count
                    result.append(ReviewGroup(id: "group:\(name)", name: name, pickOne: item.pickOne, items: [item]))
                }
            } else {
                result.append(ReviewGroup(id: "item:\(item.id)", name: nil, pickOne: false, items: [item]))
            }
        }
        return result
    }
}

/// Which part of a request a review screen shows.
public enum ReviewFilter: String, CaseIterable, Sendable, Identifiable {
    /// What still has no decision or answer (with the other options of an open pick-one group).
    case waiting
    /// What has a decision or an answer.
    case answered
    case all

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .waiting: return "Waiting"
        case .answered: return "Answered"
        case .all: return "All"
        }
    }

    /// How many entries of the request the filter is about.
    public func count(in summary: ReviewSummary) -> Int {
        switch self {
        case .waiting: return summary.pending
        case .answered: return summary.total - summary.pending
        case .all: return summary.total
        }
    }
}

/// One thing to answer in a request: a question or an item.
public enum ReviewEntry: Identifiable, Hashable, Sendable {
    case question(ReviewQuestion)
    case item(ReviewItem)

    public var id: String {
        switch self {
        case .question(let question): return "question:\(question.id)"
        case .item(let item): return "item:\(item.id)"
        }
    }

    /// Still waiting for the reviewer: an item without a decision, a question without an answer.
    public var isWaiting: Bool {
        switch self {
        case .question(let question): return !question.isAnswered
        case .item(let item): return item.status == .pending
        }
    }

    /// The first waiting entry after the one with `id` (wrapping round to the start), or the
    /// first waiting one when `id` is `nil` or not among them. `nil` when nothing waits.
    public static func nextWaiting(after id: String?, in entries: [ReviewEntry]) -> ReviewEntry? {
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return entries.first(where: \.isWaiting) }
        return entries[(index + 1)...].first(where: \.isWaiting) ?? entries[..<index].first(where: \.isWaiting)
    }
}

/// Addresses one review request: the source it lives in and its folder there.
public struct ReviewRef: Hashable, Sendable, Identifiable {
    public var origin: String
    public var folder: String
    public init(origin: String, folder: String) { self.origin = origin; self.folder = folder }
    public var id: String { "\(origin)|\(folder)" }
}

public struct ReviewGroup: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String?
    public var pickOne: Bool
    public var items: [ReviewItem]
}

public enum ReviewError: Error, LocalizedError, Equatable {
    case itemNotFound(String)
    case questionNotFound(String)
    case emptyComment
    case malformed
    case emptyAnswer
    case unknownOption(String)
    case oneChoiceOnly
    case otherNotAllowed
    case alreadyHandled(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound(let id): return "No review item with id \"\(id)\"."
        case .questionNotFound(let id): return "No question with id \"\(id)\"."
        case .emptyComment: return "A review comment needs text."
        case .malformed: return "The review file has no readable frontmatter."
        case .emptyAnswer: return "Choose an option or write an answer."
        case .unknownOption(let id): return "\"\(id)\" is not an option of this question."
        case .oneChoiceOnly: return "This question takes one answer."
        case .otherNotAllowed: return "This question has no room for an answer of your own."
        case .alreadyHandled(let id): return "The agent has already acted on the answer to \"\(id)\", so it can no longer change."
        }
    }
}

public enum Review {
    public static let fileName = "review.md"

    // MARK: Parse

    public static func parse(_ text: String, folder: String) -> ReviewRequest {
        let fallbackID = folder.split(separator: "/").last.map(String.init) ?? "review"
        let (yaml, body) = BoardMarkdown.splitFrontmatter(text)
        var problem: String?
        var node: Node?
        if let yaml {
            do { node = try composeLeniently(yaml) } catch { problem = describe(error) }
        }
        let map = node?.mapping
        let rawItems = map?["items"]?.sequence.map(Array.init) ?? []
        let items = rawItems.enumerated().compactMap { parseItem($0.element, index: $0.offset) }
        let rawQuestions = map?["questions"]?.sequence.map(Array.init) ?? []
        let questions = rawQuestions.enumerated().compactMap { parseQuestion($0.element, index: $0.offset) }
        let id = string(map?["id"]) ?? fallbackID
        return ReviewRequest(
            folder: folder,
            id: id,
            project: string(map?["project"]),
            card: string(map?["card"]),
            title: string(map?["title"]) ?? id,
            question: string(map?["question"]),
            requestedBy: string(map?["requested_by"]),
            requestedAt: string(map?["requested_at"]),
            items: items,
            questions: questions,
            body: yaml == nil ? text : body,
            problem: problem
        )
    }

    /// The frontmatter as YAML, or, when it is not valid YAML, as YAML once the slips agents
    /// make writing it by hand are mended (see `mendedYAML`). Valid YAML is never changed.
    static func composeLeniently(_ yaml: String) throws -> Node? {
        do {
            return try Yams.compose(yaml: yaml)
        } catch {
            let mended = mendedYAML(yaml)
            guard mended != yaml, let node = try? Yams.compose(yaml: mended) else { throw error }
            return node
        }
    }

    /// Mends the two slips seen in real requests, line by line, outside block scalars:
    /// a double-quoted value with quotes inside it (`note: "one line, "Bought 24 stone", …"`)
    /// and a plain value with `: ` or ` #` in it (`note: Diagnostic pair: the good state.`).
    /// Each becomes a single-quoted value with the same text.
    static func mendedYAML(_ yaml: String) -> String {
        var out: [String] = []
        var blockIndent: Int?
        for line in yaml.components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " }.count
            if let block = blockIndent {
                if line.trimmingCharacters(in: .whitespaces).isEmpty || indent > block { out.append(line); continue }
                blockIndent = nil
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = keyValueLine.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line) else {
                out.append(line)
                continue
            }
            let key = String(line[keyRange]), value = String(line[valueRange])
            guard let first = value.first else { out.append(line); continue }
            if first == "|" || first == ">" { blockIndent = indent; out.append(line); continue }
            var text: String?
            if first == "\"" {
                let inner = value.count > 1 && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : nil
                if let inner, inner.range(of: #"(?<!\\)""#, options: .regularExpression) != nil {
                    text = inner.replacingOccurrences(of: "\\\"", with: "\"")
                }
            } else if !"'[{&*!%@`".contains(first), value.contains(": ") || value.contains(" #") {
                text = value
            }
            if let text {
                out.append("\(key): '\(text.replacingOccurrences(of: "'", with: "''"))'")
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// `key: value` or `- key: value`, the key with its indent and dash.
    private static let keyValueLine = try! NSRegularExpression(pattern: #"^(\s*(?:- )?[A-Za-z_][\w-]*):[ \t]+(.+?)\s*$"#)

    /// A YAML error as one readable line, with where it is in `review.md` (the frontmatter
    /// starts on line 2).
    private static func describe(_ error: Error) -> String {
        guard let yaml = error as? YamlError else { return error.localizedDescription }
        switch yaml {
        case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _), .composer(_, let problem, let mark, _):
            return "Line \(mark.line + 1): \(problem)."
        default:
            return String(describing: yaml).components(separatedBy: "\n").first ?? "The frontmatter is not valid YAML."
        }
    }

    private static func parseComments(_ node: Node?) -> [ReviewComment] {
        (node?.sequence.map(Array.init) ?? []).compactMap { entry in
            guard let c = entry.mapping, let text = string(c["text"]) else { return nil }
            return ReviewComment(by: string(c["by"]) ?? "unknown", at: string(c["at"]) ?? "", text: text, image: string(c["image"]))
        }
    }

    /// A question needs its text; options without a label show their id. The answer is read
    /// as the model allows it: only ids of its options, and at most one for `select: one`.
    private static func parseQuestion(_ node: Node, index: Int) -> ReviewQuestion? {
        guard let map = node.mapping, let text = string(map["question"]) else { return nil }
        let select = string(map["select"]).flatMap { QuestionSelect(rawValue: $0.lowercased()) } ?? .one
        let options: [ReviewQuestionOption] = (map["options"]?.sequence.map(Array.init) ?? []).enumerated().compactMap { offset, entry in
            if let option = entry.mapping {
                let id = string(option["id"]) ?? "option-\(offset + 1)"
                return ReviewQuestionOption(id: id, label: string(option["label"]) ?? id, detail: string(option["detail"]))
            }
            // A bare `- iCloud only` is an option whose label is its id.
            return string(entry).map { ReviewQuestionOption(id: $0, label: $0) }
        }
        let ids = Set(options.map(\.id))
        var answer = answerIDs(map["answer"]).filter(ids.contains)
        if select == .one { answer = Array(answer.prefix(1)) }
        let allowsOther = bool(map["other"])
        return ReviewQuestion(
            id: string(map["id"]) ?? "question-\(index + 1)",
            question: text,
            detail: string(map["detail"]),
            select: select,
            allowsOther: allowsOther,
            options: options,
            answer: options.map(\.id).filter(answer.contains),
            answerOther: allowsOther ? string(map["answer_other"]) : nil,
            answeredBy: string(map["answered_by"]),
            answeredAt: string(map["answered_at"]),
            comments: parseComments(map["comments"]),
            handledAt: string(map["handled_at"])
        )
    }

    /// `answer: [a, b]`, or a single `answer: a`.
    private static func answerIDs(_ node: Node?) -> [String] {
        if let list = node?.sequence { return list.compactMap { string($0) } }
        return string(node).map { [$0] } ?? []
    }

    private static func bool(_ node: Node?) -> Bool {
        ["true", "yes", "on"].contains(string(node)?.lowercased() ?? "")
    }

    private static func parseItem(_ node: Node, index: Int) -> ReviewItem? {
        guard let map = node.mapping, let file = string(map["file"]) else { return nil }
        let kind = string(map["kind"]).flatMap(ReviewKind.init(rawValue:)) ?? ReviewKind.forFile(file)
        let status = string(map["status"]).flatMap(ReviewStatus.init(rawValue:)) ?? .pending
        let comments = parseComments(map["comments"])
        return ReviewItem(
            id: string(map["id"]) ?? "item-\(index + 1)",
            file: file,
            preview: string(map["preview"]),
            kind: kind,
            group: string(map["group"]),
            pickOne: string(map["pick"]) == "one",
            note: string(map["note"]),
            revises: string(map["revises"]),
            status: status,
            decidedBy: string(map["decided_by"]),
            decidedAt: string(map["decided_at"]),
            comments: comments,
            handledAt: string(map["handled_at"]),
            shippedTo: string(map["shipped_to"]),
            frames: string(map["frames"]).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil },
            fps: string(map["fps"]).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// A scalar as trimmed text; `nil` for absent, null (`~`, `null`, empty) or non-scalar.
    private static func string(_ node: Node?) -> String? {
        guard let scalar = node?.scalar else { return nil }
        let value = scalar.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || (scalar.style == .plain && ["~", "null", "Null", "NULL"].contains(value)) { return nil }
        return value
    }

    // MARK: Reviewer writes

    /// Record a decision on one item. Only `status`, `decided_by`, `decided_at` change;
    /// `pending` clears the decision.
    public static func applyDecision(
        _ text: String, itemID: String, status: ReviewStatus, by: String, at: Date = Date()
    ) throws -> String {
        let stamp = timestamp(at)
        return try mutateItem(text, itemID: itemID) { item in
            item["status"] = scalar(status.rawValue)
            if status == .pending {
                item["decided_by"] = null
                item["decided_at"] = null
            } else {
                item["decided_by"] = scalar(by)
                item["decided_at"] = scalar(stamp)
            }
        }
    }

    /// Append a comment to one item. Existing comments are never rewritten.
    /// `image` is a marked-up copy of the item, already written next to the request.
    public static func appendComment(
        _ text: String, itemID: String, by: String, body: String, image: String? = nil, at: Date = Date()
    ) throws -> String {
        let comment = try commentNode(by: by, body: body, image: image, at: at)
        return try mutateItem(text, itemID: itemID) { append(comment, to: &$0) }
    }

    /// Append a comment to one question. Existing comments are never rewritten.
    public static func appendQuestionComment(
        _ text: String, questionID: String, by: String, body: String, at: Date = Date()
    ) throws -> String {
        let comment = try commentNode(by: by, body: body, image: nil, at: at)
        return try mutateQuestion(text, questionID: questionID) { append(comment, to: &$0) }
    }

    /// Answer a question, or change the answer while the agent has not acted on it yet.
    /// Only `answer`, `answer_other`, `answered_by` and `answered_at` change (and a comment
    /// is appended when one is given). The answer is checked against the question as the
    /// file has it: known option ids only, one choice in all for `select: one` (an option or
    /// the reviewer's own answer), an own answer only where `other` allows it.
    public static func applyAnswer(
        _ text: String, questionID: String, choices: [String], other: String?, comment: String? = nil,
        by: String, at: Date = Date()
    ) throws -> String {
        let stamp = timestamp(at)
        let own = other?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let note = try comment?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            .map { try commentNode(by: by, body: $0, image: nil, at: at) }
        return try mutateQuestion(text, questionID: questionID) { raw in
            guard let question = parseQuestion(.mapping(raw), index: 0) else { throw ReviewError.malformed }
            guard question.handledAt == nil else { throw ReviewError.alreadyHandled(questionID) }
            let known = question.options.map(\.id)
            if let unknown = choices.first(where: { !known.contains($0) }) { throw ReviewError.unknownOption(unknown) }
            if own != nil, !question.allowsOther { throw ReviewError.otherNotAllowed }
            let picked = known.filter(choices.contains)
            if picked.isEmpty, own == nil { throw ReviewError.emptyAnswer }
            if question.select == .one, picked.count + (own == nil ? 0 : 1) > 1 { throw ReviewError.oneChoiceOnly }
            raw["answer"] = .sequence(Node.Sequence(picked.map(scalar)))
            raw["answer_other"] = own.map(scalar) ?? null
            raw["answered_by"] = scalar(by)
            raw["answered_at"] = scalar(stamp)
            if let note { append(note, to: &raw) }
        }
    }

    // MARK: Agent writes

    /// Record that the agent acted on an item's decision: `handled_at`, and where an
    /// approved file went (`shipped_to`). Nothing else changes.
    public static func markHandled(_ text: String, itemID: String, shippedTo: String?, at: Date = Date()) throws -> String {
        let stamp = timestamp(at)
        return try mutateItem(text, itemID: itemID) { item in
            item["handled_at"] = scalar(stamp)
            if let shippedTo, !shippedTo.isEmpty { item["shipped_to"] = scalar(shippedTo) }
        }
    }

    /// Record that the agent acted on a question's answer: `handled_at`. From then on the
    /// answer stays as it is.
    public static func markQuestionHandled(_ text: String, questionID: String, at: Date = Date()) throws -> String {
        let stamp = timestamp(at)
        return try mutateQuestion(text, questionID: questionID) { $0["handled_at"] = scalar(stamp) }
    }

    /// An item an agent submits for review.
    public struct NewItem: Sendable, Equatable {
        public var id: String
        public var file: String
        public var preview: String?
        public var kind: String?
        public var group: String?
        public var pickOne: Bool
        public var note: String?
        public var revises: String?
        public init(id: String, file: String, preview: String? = nil, kind: String? = nil, group: String? = nil,
                    pickOne: Bool = false, note: String? = nil, revises: String? = nil) {
            self.id = id; self.file = file; self.preview = preview; self.kind = kind
            self.group = group; self.pickOne = pickOne; self.note = note; self.revises = revises
        }
    }

    /// A question an agent asks.
    public struct NewQuestion: Sendable, Equatable {
        public var id: String
        public var question: String
        public var detail: String?
        public var select: QuestionSelect
        public var allowsOther: Bool
        public var options: [ReviewQuestionOption]
        public init(id: String, question: String, detail: String? = nil, select: QuestionSelect = .one,
                    allowsOther: Bool = false, options: [ReviewQuestionOption]) {
            self.id = id; self.question = question; self.detail = detail; self.select = select
            self.allowsOther = allowsOther; self.options = options
        }
    }

    private static func node(_ item: NewItem) -> Node {
        var pairs: [(Node, Node)] = [(scalar("id"), scalar(item.id)), (scalar("file"), scalar(item.file))]
        func add(_ key: String, _ value: String?) { if let value, !value.isEmpty { pairs.append((scalar(key), scalar(value))) } }
        add("preview", item.preview)
        add("kind", item.kind)
        add("group", item.group)
        if item.pickOne { add("pick", "one") }
        add("note", item.note)
        add("revises", item.revises)
        pairs.append((scalar("status"), scalar(ReviewStatus.pending.rawValue)))
        pairs.append((scalar("comments"), Node.sequence(Node.Sequence([]))))
        return .mapping(Node.Mapping(pairs))
    }

    private static func node(_ question: NewQuestion) -> Node {
        var pairs: [(Node, Node)] = [(scalar("id"), scalar(question.id)), (scalar("question"), scalar(question.question))]
        if let detail = question.detail?.nilIfEmpty { pairs.append((scalar("detail"), scalar(detail))) }
        pairs.append((scalar("select"), scalar(question.select.rawValue)))
        if question.allowsOther { pairs.append((scalar("other"), Node("true", Tag(.bool)))) }
        let options = question.options.map { option -> Node in
            var entry: [(Node, Node)] = [(scalar("id"), scalar(option.id)), (scalar("label"), scalar(option.label))]
            if let detail = option.detail?.nilIfEmpty { entry.append((scalar("detail"), scalar(detail))) }
            return .mapping(Node.Mapping(entry))
        }
        pairs.append((scalar("options"), .sequence(Node.Sequence(options))))
        pairs.append((scalar("answer"), .sequence(Node.Sequence([]))))
        for key in ["answer_other", "answered_by", "answered_at"] { pairs.append((scalar(key), null)) }
        pairs.append((scalar("comments"), .sequence(Node.Sequence([]))))
        pairs.append((scalar("handled_at"), null))
        return .mapping(Node.Mapping(pairs))
    }

    /// A new request's `review.md`. A request holds items, questions, or both; a list that
    /// is empty is left out.
    public static func render(
        id: String, project: String?, card: String?, title: String, question: String?,
        requestedBy: String, at: Date = Date(), notes: String?, items: [NewItem], questions: [NewQuestion] = []
    ) throws -> String {
        var pairs: [(Node, Node)] = [(scalar("config"), scalar("review")), (scalar("id"), scalar(id))]
        func add(_ key: String, _ value: String?) { if let value, !value.isEmpty { pairs.append((scalar(key), scalar(value))) } }
        add("project", project)
        add("card", card)
        add("title", title)
        add("question", question)
        add("requested_by", requestedBy)
        add("requested_at", timestamp(at))
        if !items.isEmpty || questions.isEmpty {
            pairs.append((scalar("items"), Node.sequence(Node.Sequence(items.map(node)))))
        }
        if !questions.isEmpty {
            pairs.append((scalar("questions"), Node.sequence(Node.Sequence(questions.map(node)))))
        }
        let yaml = try Yams.serialize(node: .mapping(Node.Mapping(pairs)), width: -1, allowUnicode: true)
        let trimmed = yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
        let body = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "---\n\(trimmed)\n---\n" + (body.isEmpty ? "" : "\n\(body)\n")
    }

    /// Add items and questions to an existing request (a new round). What is there is left as it is.
    public static func appendItems(_ text: String, _ new: [NewItem], questions: [NewQuestion] = []) throws -> String {
        try mutateFrontmatter(text) { map in
            if !new.isEmpty {
                let items = map["items"]?.sequence.map(Array.init) ?? []
                map["items"] = .sequence(Node.Sequence(items + new.map(node)))
            }
            if !questions.isEmpty {
                let existing = map["questions"]?.sequence.map(Array.init) ?? []
                map["questions"] = .sequence(Node.Sequence(existing + questions.map(node)))
            }
        }
    }

    private static func commentNode(by: String, body: String, image: String?, at: Date) throws -> Node {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReviewError.emptyComment }
        var pairs = [
            (scalar("by"), scalar(by)),
            (scalar("at"), scalar(timestamp(at))),
            (scalar("text"), scalar(trimmed)),
        ]
        if let image, !image.isEmpty { pairs.append((scalar("image"), scalar(image))) }
        return Node.mapping(Node.Mapping(pairs))
    }

    private static func append(_ comment: Node, to entry: inout Node.Mapping) {
        var list = entry["comments"]?.sequence.map(Array.init) ?? []
        list.append(comment)
        entry["comments"] = Node.sequence(Node.Sequence(list))
    }

    private static func mutateItem(_ text: String, itemID: String, _ change: (inout Node.Mapping) throws -> Void) throws -> String {
        try mutateEntry(text, list: "items", id: itemID, fallback: "item", notFound: ReviewError.itemNotFound(itemID), change)
    }

    private static func mutateQuestion(_ text: String, questionID: String, _ change: (inout Node.Mapping) throws -> Void) throws -> String {
        try mutateEntry(text, list: "questions", id: questionID, fallback: "question", notFound: ReviewError.questionNotFound(questionID), change)
    }

    /// Change one entry of the `items` or `questions` list, found by id (or by position for
    /// one without an id, as the parser names it). Everything else is written back as it was.
    private static func mutateEntry(
        _ text: String, list key: String, id: String, fallback: String, notFound: ReviewError,
        _ change: (inout Node.Mapping) throws -> Void
    ) throws -> String {
        try mutateFrontmatter(text) { map in
            guard var entries = map[key]?.sequence.map(Array.init) else { throw notFound }
            guard let index = entries.indices.first(where: { offset in
                (string(entries[offset].mapping?["id"]) ?? "\(fallback)-\(offset + 1)") == id
            }), var entry = entries[index].mapping else {
                throw notFound
            }
            try change(&entry)
            entries[index] = .mapping(entry)
            map[key] = .sequence(Node.Sequence(entries))
        }
    }

    private static func mutateFrontmatter(_ text: String, _ change: (inout Node.Mapping) throws -> Void) throws -> String {
        let (yamlText, body) = BoardMarkdown.splitFrontmatter(text)
        guard let yamlText, let root = try composeLeniently(yamlText), var map = root.mapping else {
            throw ReviewError.malformed
        }
        try change(&map)
        let yaml = try Yams.serialize(node: .mapping(map), width: -1, allowUnicode: true)
        let trimmed = yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
        return "---\n\(trimmed)\n---\n\(body)"
    }

    private static var null: Node { Node("null", Tag(.null)) }

    /// A value as written by the app: multi-line text (Markdown) as a literal block.
    private static func scalar(_ value: String) -> Node {
        value.contains("\n") ? Node(value, Tag(.str), .literal) : Node(value)
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: Paths

    /// Resolve a project's review folder from its effective `review_path` (relative to the
    /// project folder; `{folder}` = the project folder's name). `nil` when unset or escaping.
    public static func resolveReviewPath(_ reviewPath: String?, projectFolder: String) -> String? {
        guard let raw = reviewPath?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return resolve(raw, projectFolder: projectFolder)
    }

    /// Where a board keeps its reviews when it does not say: `review/` inside the board.
    public static let defaultReviewPath = "review"

    /// The folders to look for a board's review requests in: the configured one when it
    /// can be reached in this source, else the board's own `review/` folder.
    public static func reviewFolder(_ reviewPath: String?, projectFolder: String) -> String? {
        resolveReviewPath(reviewPath, projectFolder: projectFolder) ?? resolve(defaultReviewPath, projectFolder: projectFolder)
    }

    private static func resolve(_ raw: String, projectFolder: String) -> String? {
        let name = projectFolder.split(separator: "/").last.map(String.init) ?? ""
        guard let resolved = joinRelative(projectFolder, raw.replacingOccurrences(of: "{folder}", with: name)),
              !resolved.isEmpty else { return nil }
        return resolved
    }

    /// Normalize `relative` against a source-relative `base`; `nil` for absolute paths or
    /// paths that climb above the source root.
    public static func joinRelative(_ base: String, _ relative: String) -> String? {
        if relative.hasPrefix("/") || relative.contains("\\") || relative.contains("\0") { return nil }
        var out = base.split(separator: "/").map(String.init)
        for part in relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch part {
            case ".": continue
            case "..":
                if out.isEmpty { return nil }
                out.removeLast()
            default: out.append(part)
            }
        }
        return out.joined(separator: "/")
    }

    static func join(_ base: String, _ component: String) -> String {
        base.isEmpty ? component : "\(base)/\(component)"
    }
}

// MARK: Loading through a BoardFileSource

public extension RemoteBoardStore {
    /// Load every review request under a review folder (`<folder>/<request>/review.md`).
    /// A missing folder yields `[]`: a project without reviews looks exactly as before.
    static func loadReviews(source: BoardFileSource, folder: String) async -> [ReviewRequest] {
        guard let entries = try? await source.list(folder) else { return [] }
        let dirs = entries.filter { $0.kind == .directory && !$0.name.hasPrefix(".") }
        let loaded = await withTaskGroup(of: ReviewRequest?.self) { group -> [ReviewRequest] in
            for dir in dirs {
                group.addTask {
                    guard let text = try? await source.readText(Review.join(dir.path, Review.fileName)) else { return nil }
                    return Review.parse(text, folder: dir.path)
                }
            }
            var result: [ReviewRequest] = []
            for await request in group { if let request { result.append(request) } }
            return result
        }
        // Open requests first, then newest first.
        return loaded.sorted { a, b in
            let ap = a.summary.pending > 0, bp = b.summary.pending > 0
            if ap != bp { return ap }
            return (a.requestedAt ?? "") > (b.requestedAt ?? "")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
