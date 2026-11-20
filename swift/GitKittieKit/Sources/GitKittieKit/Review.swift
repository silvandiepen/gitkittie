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
    public init(by: String, at: String, text: String) { self.by = by; self.at = at; self.text = text }
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

public struct ReviewSummary: Equatable, Sendable {
    public var total = 0
    public var pending = 0
    public var approved = 0
    public var rejected = 0
    public var changesRequested = 0
    public var awaitingAgent = 0
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
    public var body: String

    public var path: String { Review.join(folder, Review.fileName) }

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
        return s
    }

    /// Source-relative path of an item's file (or preview), `nil` if it escapes the root.
    public func assetPath(_ file: String) -> String? { Review.joinRelative(folder, file) }

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

public struct ReviewGroup: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String?
    public var pickOne: Bool
    public var items: [ReviewItem]
}

public enum ReviewError: Error, LocalizedError, Equatable {
    case itemNotFound(String)
    case emptyComment
    case malformed

    public var errorDescription: String? {
        switch self {
        case .itemNotFound(let id): return "No review item with id \"\(id)\"."
        case .emptyComment: return "A review comment needs text."
        case .malformed: return "The review file has no readable frontmatter."
        }
    }
}

public enum Review {
    public static let fileName = "review.md"

    // MARK: Parse

    public static func parse(_ text: String, folder: String) -> ReviewRequest {
        let fallbackID = folder.split(separator: "/").last.map(String.init) ?? "review"
        let (yaml, body) = BoardMarkdown.splitFrontmatter(text)
        let node = yaml.flatMap { try? Yams.compose(yaml: $0) } ?? nil
        let map = node?.mapping
        let rawItems = map?["items"]?.sequence.map(Array.init) ?? []
        let items = rawItems.enumerated().compactMap { parseItem($0.element, index: $0.offset) }
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
            body: yaml == nil ? text : body
        )
    }

    private static func parseItem(_ node: Node, index: Int) -> ReviewItem? {
        guard let map = node.mapping, let file = string(map["file"]) else { return nil }
        let kind = string(map["kind"]).flatMap(ReviewKind.init(rawValue:)) ?? ReviewKind.forFile(file)
        let status = string(map["status"]).flatMap(ReviewStatus.init(rawValue:)) ?? .pending
        let comments: [ReviewComment] = (map["comments"]?.sequence.map(Array.init) ?? []).compactMap { entry in
            guard let c = entry.mapping, let text = string(c["text"]) else { return nil }
            return ReviewComment(by: string(c["by"]) ?? "unknown", at: string(c["at"]) ?? "", text: text)
        }
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
                item["decided_by"] = Node("null", Tag(.null))
                item["decided_at"] = Node("null", Tag(.null))
            } else {
                item["decided_by"] = scalar(by)
                item["decided_at"] = scalar(stamp)
            }
        }
    }

    /// Append a comment to one item. Existing comments are never rewritten.
    public static func appendComment(
        _ text: String, itemID: String, by: String, body: String, at: Date = Date()
    ) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReviewError.emptyComment }
        let comment = Node.mapping(Node.Mapping([
            (scalar("by"), scalar(by)),
            (scalar("at"), scalar(timestamp(at))),
            (scalar("text"), scalar(trimmed)),
        ]))
        return try mutateItem(text, itemID: itemID) { item in
            var list = item["comments"]?.sequence.map(Array.init) ?? []
            list.append(comment)
            item["comments"] = Node.sequence(Node.Sequence(list))
        }
    }

    private static func mutateItem(_ text: String, itemID: String, _ change: (inout Node.Mapping) -> Void) throws -> String {
        let (yamlText, body) = BoardMarkdown.splitFrontmatter(text)
        guard let yamlText, let root = try Yams.compose(yaml: yamlText), var map = root.mapping else {
            throw ReviewError.malformed
        }
        guard var items = map["items"]?.sequence.map(Array.init) else { throw ReviewError.itemNotFound(itemID) }
        guard let index = items.indices.first(where: { offset in
            (string(items[offset].mapping?["id"]) ?? "item-\(offset + 1)") == itemID
        }), var item = items[index].mapping else {
            throw ReviewError.itemNotFound(itemID)
        }
        change(&item)
        items[index] = .mapping(item)
        map["items"] = .sequence(Node.Sequence(items))
        let yaml = try Yams.serialize(node: .mapping(map), width: -1, allowUnicode: true)
        let trimmed = yaml.hasSuffix("\n") ? String(yaml.dropLast()) : yaml
        return "---\n\(trimmed)\n---\n\(body)"
    }

    private static func scalar(_ value: String) -> Node { Node(value) }

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
