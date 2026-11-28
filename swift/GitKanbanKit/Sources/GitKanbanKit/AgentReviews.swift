import Foundation
import GitKittieKit

// Review requests, for an agent: ask for a review, read the decisions, record that they
// were acted on, and clear a finished request away. The files are the same ones the
// review screens read and write (`<board>/review/<request>/review.md` and its assets).

extension AgentBoard {
    private func path(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: "/") }

    /// The folder this board's review requests live in.
    func reviewFolder() async throws -> String {
        let config = try await shell().config
        guard let folder = Review.reviewFolder(config.reviewPath, projectFolder: folder) else {
            throw AgentBoardError("This board has no place for review requests.")
        }
        return folder
    }

    private func requests() async throws -> [ReviewRequest] {
        await RemoteBoardStore.loadReviews(source: source, folder: try await reviewFolder())
    }

    private func request(_ id: String) async throws -> ReviewRequest {
        let all = try await requests()
        let key = id.lowercased()
        if let found = all.first(where: { $0.id.lowercased() == key || ($0.folder.split(separator: "/").last.map { $0.lowercased() } == key) }) {
            return found
        }
        throw AgentBoardError("No review request \"\(id)\" on this board. The requests are: \(all.map(\.id).joined(separator: ", ")).")
    }

    static func describe(_ item: ReviewItem) -> [String: Any] {
        var out: [String: Any] = ["id": item.id, "file": item.file, "kind": item.kind.rawValue, "status": item.status.rawValue,
                                  "to_handle": item.awaitingAgent]
        out["note"] = item.note
        out["group"] = item.group
        out["revises"] = item.revises
        out["decided_by"] = item.decidedBy
        out["decided_at"] = item.decidedAt
        out["handled_at"] = item.handledAt
        out["shipped_to"] = item.shippedTo
        if !item.comments.isEmpty { out["comments"] = comments(item.comments) }
        return out
    }

    static func comments(_ comments: [ReviewComment]) -> [[String: Any]] {
        comments.map { comment -> [String: Any] in
            var entry: [String: Any] = ["by": comment.by, "at": comment.at, "text": comment.text]
            // A marked-up copy of the file, in the request's folder.
            entry["image"] = comment.image
            return entry
        }
    }

    static func describe(_ question: ReviewQuestion) -> [String: Any] {
        var out: [String: Any] = [
            "id": question.id, "question": question.question, "select": question.select.rawValue,
            "other": question.allowsOther, "status": question.isAnswered ? "answered" : "pending",
            "to_handle": question.awaitingAgent,
            "options": question.options.map { option -> [String: Any] in
                var entry: [String: Any] = ["id": option.id, "label": option.label]
                entry["detail"] = option.detail
                return entry
            },
        ]
        out["detail"] = question.detail
        if question.isAnswered {
            out["answer"] = question.answer
            out["answer_labels"] = question.chosen.map(\.label)
        }
        out["answer_other"] = question.answerOther
        out["answered_by"] = question.answeredBy
        out["answered_at"] = question.answeredAt
        out["handled_at"] = question.handledAt
        if !question.comments.isEmpty { out["comments"] = comments(question.comments) }
        return out
    }

    static func describe(_ request: ReviewRequest, items: [ReviewItem]? = nil, questions: [ReviewQuestion]? = nil) -> [String: Any] {
        let summary = request.summary
        var out: [String: Any] = [
            "request": request.id, "title": request.title, "folder": request.folder,
            "pending": summary.pending, "to_handle": summary.awaitingAgent,
            "items": (items ?? request.items).map(describe),
        ]
        let questions = questions ?? request.questions
        if !questions.isEmpty { out["questions"] = questions.map(describe) }
        out["card"] = request.card
        out["question"] = request.question
        out["requested_by"] = request.requestedBy
        out["requested_at"] = request.requestedAt
        out["notify"] = request.notify.rawValue
        return out
    }

    /// The board's review requests. `state`: `to_handle` (decided or answered by the
    /// reviewer, not yet acted on: only those items and questions are listed), `pending`
    /// (still waiting for the reviewer), or `all`.
    public func listReviews(state: String?, card: String?) async throws -> [[String: Any]] {
        let wanted = (state ?? "to_handle").lowercased()
        guard ["to_handle", "pending", "all"].contains(wanted) else {
            throw AgentBoardError("\"state\" is to_handle, pending or all.")
        }
        var all = try await requests()
        if let card { all = all.filter { $0.card?.lowercased() == card.lowercased() } }
        return all.compactMap { request -> [String: Any]? in
            switch wanted {
            case "to_handle":
                let items = request.items.filter(\.awaitingAgent)
                let questions = request.questions.filter(\.awaitingAgent)
                return items.isEmpty && questions.isEmpty ? nil : Self.describe(request, items: items, questions: questions)
            case "pending":
                return request.summary.pending > 0 ? Self.describe(request) : nil
            default:
                return Self.describe(request)
            }
        }
    }

    /// A file handed over with a review item.
    public struct ReviewUpload {
        public var item: Review.NewItem
        public var data: Data
        public var preview: Data?
        public init(item: Review.NewItem, data: Data, preview: Data? = nil) { self.item = item; self.data = data; self.preview = preview }
    }

    static func safeFileName(_ raw: String) throws -> String {
        let name = String(raw.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
        guard !name.trimmingCharacters(in: CharacterSet(charactersIn: ".-")).isEmpty, !name.hasPrefix("."), name.lowercased() != Review.fileName else {
            throw AgentBoardError("\"\(raw)\" cannot be a file name here.")
        }
        return name
    }

    /// Check the questions an agent asks before anything is written: ids that are free in
    /// the request, a question text, options with ids and labels, and something to answer
    /// with (an option, or room for an own answer).
    static func validate(_ questions: [Review.NewQuestion], taken: inout Set<String>) throws {
        for question in questions {
            guard !question.id.isEmpty, taken.insert(question.id.lowercased()).inserted else {
                throw AgentBoardError("Question id \"\(question.id)\" is empty or already used in this request. Give every item and question its own id.")
            }
            guard !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentBoardError("Question \"\(question.id)\" needs its \"question\" text.")
            }
            guard !question.options.isEmpty || question.allowsOther else {
                throw AgentBoardError("Question \"\(question.id)\" needs options, or \"other\": true for a free answer.")
            }
            var optionIDs = Set<String>()
            for option in question.options {
                guard !option.id.isEmpty, optionIDs.insert(option.id).inserted else {
                    throw AgentBoardError("Option id \"\(option.id)\" of question \"\(question.id)\" is empty or used twice.")
                }
                guard !option.label.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw AgentBoardError("Option \"\(option.id)\" of question \"\(question.id)\" needs a label.")
                }
            }
        }
    }

    /// Ask for a review: write the files and the request. With the id of an existing
    /// request the items and questions are added to it (a new round), which is how a redo
    /// is submitted. A request holds files to judge, questions to answer, or both.
    public func createReview(request existing: String?, card: String?, title: String?, question: String?, notes: String?,
                             uploads: [ReviewUpload], questions: [Review.NewQuestion] = [], notify: ReviewNotify? = nil,
                             agent: String) async throws -> [String: Any] {
        guard !uploads.isEmpty || !questions.isEmpty || (existing != nil && notify != nil) else {
            throw AgentBoardError("A review request needs at least one item or question.")
        }
        let shell = try await shell()
        let root = try await reviewFolder()
        let all = await RemoteBoardStore.loadReviews(source: source, folder: root)

        var current: ReviewRequest?
        let id: String
        if let existing {
            let found = try await request(existing)
            current = found
            id = found.id
        } else {
            guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw AgentBoardError("A new review request needs a title.") }
            let base = [card, Self.slug(title)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "-")
            var candidate = base.isEmpty ? "review" : base
            var n = 2
            while all.contains(where: { $0.id.lowercased() == candidate.lowercased() || $0.folder.hasSuffix("/" + candidate) }) {
                candidate = "\(base)-\(n)"; n += 1
            }
            id = candidate
        }
        if let card {
            // A request points at a card of this board: catch a typo before anything is written.
            _ = try await find(card, in: shell)
        }
        let requestFolder = current?.folder ?? path(root, id)

        var taken = Set(((current?.items.map(\.id) ?? []) + (current?.questions.map(\.id) ?? [])).map { $0.lowercased() })
        try Self.validate(questions, taken: &taken)
        var items: [Review.NewItem] = []
        var files: [(String, Data)] = []
        for upload in uploads {
            var item = upload.item
            guard !item.id.isEmpty, taken.insert(item.id.lowercased()).inserted else {
                throw AgentBoardError("Item id \"\(item.id)\" is empty or already used in this request. Give every item and question its own id.")
            }
            guard !upload.data.isEmpty else { throw AgentBoardError("The file of item \"\(item.id)\" is empty.") }
            if let revises = item.revises, current?.items.contains(where: { $0.id == revises }) != true {
                throw AgentBoardError("Item \"\(item.id)\" revises \"\(revises)\", which is not an item of this request.")
            }
            if let kind = item.kind, ReviewKind(rawValue: kind) == nil {
                throw AgentBoardError("kind \"\(kind)\" is not one of: \(ReviewKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            item.file = try Self.safeFileName(item.file)
            files.append((item.file, upload.data))
            if let preview = upload.preview, let name = item.preview {
                item.preview = try Self.safeFileName(name)
                files.append((item.preview!, preview))
            } else {
                item.preview = nil
            }
            items.append(item)
        }
        for (name, data) in files {
            try await source.writeData(path: path(requestFolder, name), data: data, message: "chore(tasks): add \(name) to review \(id)")
        }
        var text: String
        if let current {
            text = try Review.appendItems(try await source.readText(current.path), items, questions: questions)
            if let notify { text = try Review.setNotify(text, notify) }
        } else {
            text = try Review.render(id: id, project: shell.project.name, card: card, title: title ?? id, question: question,
                                     requestedBy: agent, at: now(), notes: notes, items: items, questions: questions,
                                     notify: notify)
        }
        try await source.write(path: path(requestFolder, Review.fileName), text: text,
                               message: current == nil ? "chore(tasks): request review \(id)" : "chore(tasks): add a round to review \(id)")
        var out: [String: Any] = ["request": id, "folder": requestFolder, "items": items.map(\.id)]
        if !questions.isEmpty { out["questions"] = questions.map(\.id) }
        if let notify { out["notify"] = notify.rawValue }
        return out
    }

    /// Record that a decided item or an answered question was acted on. When that leaves
    /// nothing pending and nothing to handle, the request is finished and (unless `keep`)
    /// cleared away. An answered question is fixed from then on.
    public func handleReviewItem(request id: String, item itemID: String, shippedTo: String?, keep: Bool) async throws -> [String: Any] {
        let found = try await request(id)
        let text: String
        if let item = found.items.first(where: { $0.id == itemID }) {
            guard item.status != .pending else {
                throw AgentBoardError("\(itemID) has no decision yet, so there is nothing to handle. Wait for the reviewer.")
            }
            text = try Review.markHandled(try await source.readText(found.path), itemID: itemID, shippedTo: shippedTo, at: now())
        } else if let question = found.questions.first(where: { $0.id == itemID }) {
            guard question.isAnswered else {
                throw AgentBoardError("Question \(itemID) has no answer yet, so there is nothing to handle. Wait for the reviewer.")
            }
            text = try Review.markQuestionHandled(try await source.readText(found.path), questionID: itemID, at: now())
        } else {
            let ids = found.items.map(\.id) + found.questions.map(\.id)
            throw AgentBoardError("No item or question \"\(itemID)\" in \(found.id). They are: \(ids.joined(separator: ", ")).")
        }
        try await source.write(path: found.path, text: text, message: "chore(tasks): handle \(itemID) of review \(found.id)")
        let fresh = Review.parse(text, folder: found.folder)
        let summary = fresh.summary
        var out: [String: Any] = ["request": fresh.id, "item": itemID, "pending": summary.pending, "to_handle": summary.awaitingAgent]
        if summary.pending == 0, summary.awaitingAgent == 0 {
            if keep {
                out["finished"] = true
            } else {
                out["closed"] = try await remove(fresh)
            }
        }
        return out
    }

    /// Clear a finished request away: its folder and files. Refused while the reviewer
    /// still has items to decide or the agent has decisions to act on, unless `force`.
    public func closeReview(request id: String, force: Bool) async throws -> [String: Any] {
        let found = try await request(id)
        let summary = found.summary
        if !force, summary.pending > 0 || summary.awaitingAgent > 0 {
            let open = found.items.filter { $0.status == .pending }.map(\.id) + found.questions.filter { !$0.isAnswered }.map(\.id)
            let unhandled = found.items.filter(\.awaitingAgent).map(\.id) + found.questions.filter(\.awaitingAgent).map(\.id)
            throw AgentBoardError("\(found.id) is not finished. Waiting for the reviewer: \(open.isEmpty ? "none" : open.joined(separator: ", ")). Decided or answered but not handled: \(unhandled.isEmpty ? "none" : unhandled.joined(separator: ", ")). Handle those first, or pass force.")
        }
        return ["request": found.id, "closed": try await remove(found)]
    }

    /// Delete a request's files (those directly in its folder, and one level below).
    private func remove(_ request: ReviewRequest) async throws -> Int {
        var files: [String] = []
        for entry in try await source.list(request.folder) {
            if entry.kind == .directory {
                files += ((try? await source.list(entry.path)) ?? []).filter { $0.kind == .file }.map(\.path)
            } else {
                files.append(entry.path)
            }
        }
        // The request file goes last: until then the request still shows, with what is left.
        let ordered = files.filter { !$0.hasSuffix("/" + Review.fileName) } + files.filter { $0.hasSuffix("/" + Review.fileName) }
        for file in ordered {
            try await source.delete(path: file, message: "chore(tasks): close review \(request.id)")
        }
        return ordered.count
    }

    /// Wait until the reviewer has decided or answered something that is not handled yet, and return
    /// it; an empty list when `timeout` passes first. Looks every `interval` seconds.
    public func waitForReviews(card: String?, timeout: TimeInterval, interval: TimeInterval = 15) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let found = try await listReviews(state: "to_handle", card: card)
            if !found.isEmpty || Date() >= deadline { return found }
            try await Task.sleep(nanoseconds: UInt64(max(1, min(interval, deadline.timeIntervalSinceNow)) * 1_000_000_000))
        }
    }
}
