import Foundation
import Yams

// Browser checks (ReviewSpec § 3), mirroring `review-checks.ts` in `@gitkittie/gitkanban-core`:
// "open this page and check these things, at these sizes". A check is a top-level `checks:`
// entry next to `items:` and `questions:`. Each line of its checklist is answered pass, fail
// or with a note, per size (and per appearance when the check lists light and dark); the
// check as a whole is decided like a file and counts toward the request's outcome.

public enum CheckUserAgent: String, CaseIterable, Sendable, Codable {
    case mobile, desktop, `default`
}

public enum CheckAppearance: String, CaseIterable, Sendable, Codable {
    case light, dark
}

public enum CheckAnswerResult: String, CaseIterable, Sendable, Codable {
    case pass, fail, note
}

/// A size a check is looked at in.
public struct CheckSize: Equatable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    /// CSS pixels; `nil` for `default` and for an id this version does not know.
    public var width: Int?
    public var height: Int?
    public var ua: CheckUserAgent

    public init(id: String, label: String, width: Int? = nil, height: Int? = nil, ua: CheckUserAgent = .default) {
        self.id = id; self.label = label; self.width = width; self.height = height; self.ua = ua
    }

    /// The size a check without `sizes` has: whatever window or screen it is opened in.
    public static let defaultID = "default"
    /// Results taken at a size the reviewer chose freely on the Mac.
    public static let customID = "custom"

    /// Generic names, so they don't age with device models.
    public static let presets: [CheckSize] = [
        CheckSize(id: "phone-small", label: "Small phone", width: 375, height: 667, ua: .mobile),
        CheckSize(id: "phone", label: "Phone", width: 390, height: 844, ua: .mobile),
        CheckSize(id: "phone-large", label: "Large phone", width: 440, height: 956, ua: .mobile),
        CheckSize(id: "tablet", label: "Tablet", width: 820, height: 1180, ua: .mobile),
        CheckSize(id: "tablet-landscape", label: "Tablet landscape", width: 1180, height: 820, ua: .mobile),
        CheckSize(id: "laptop", label: "Laptop", width: 1280, height: 800, ua: .desktop),
        CheckSize(id: "desktop", label: "Desktop", width: 1440, height: 900, ua: .desktop),
        CheckSize(id: "wide", label: "Wide", width: 1920, height: 1080, ua: .desktop),
    ]

    /// `"390x844"`, or `nil` without dimensions.
    public var viewport: String? {
        guard let width, let height else { return nil }
        return "\(width)x\(height)"
    }

    /// `WIDTHxHEIGHT` as numbers.
    public static func dimensions(_ text: String) -> (Int, Int)? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), (2...5).contains(parts[0].count),
              (2...5).contains(parts[1].count), w > 0, h > 0 else { return nil }
        return (w, h)
    }
}

public struct CheckLine: Equatable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public init(id: String, text: String) { self.id = id; self.text = text }

    /// A line id made from its text: lower case words joined by `-` (at most 40 characters).
    public static func id(for text: String, index: Int = 0) -> String {
        var out = ""
        var dash = false
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.unicodeScalars.append(scalar)
            } else {
                dash = true
            }
        }
        var slug = String(out.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "line-\(index + 1)" : slug
    }
}

public struct CheckAnswer: Equatable, Sendable, Hashable {
    public var result: CheckAnswerResult
    public var note: String?
    public var at: String?
    public init(result: CheckAnswerResult, note: String? = nil, at: String? = nil) { self.result = result; self.note = note; self.at = at }
}

/// What was found at one size (and appearance).
public struct CheckResult: Equatable, Sendable, Hashable {
    public var viewport: String?
    public var by: String?
    public var at: String?
    /// Relative to the request folder, `results/<check>-<key>.png`.
    public var screenshot: String?
    /// By checklist line id.
    public var answers: [String: CheckAnswer] = [:]
    public init(viewport: String? = nil, by: String? = nil, at: String? = nil, screenshot: String? = nil, answers: [String: CheckAnswer] = [:]) {
        self.viewport = viewport; self.by = by; self.at = at; self.screenshot = screenshot; self.answers = answers
    }
}

/// One failed (or noted) line, as `list_reviews` reports it.
public struct CheckFailure: Equatable, Sendable, Hashable {
    public var size: String
    public var item: String
    public var text: String
    public var result: CheckAnswerResult
    public var note: String?
    public var screenshot: String?
}

/// A browser check in a review request. The agent writes the page, sizes and checklist; the
/// reviewer writes `results`, `status`, `decided_by`, `decided_at`.
public struct ReviewCheck: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var url: String
    public var title: String?
    public var note: String?
    public var sizes: [CheckSize]
    public var appearance: [CheckAppearance]
    public var checklist: [CheckLine]
    public var revises: String?
    public var actions: ReviewActions
    /// By size key: `<size id>` or `<size id>.<appearance>`.
    public var results: [String: CheckResult]
    public var status: ReviewStatus
    public var decidedBy: String?
    public var decidedAt: String?
    public var comments: [ReviewComment]
    public var handledAt: String?

    /// Decided by the reviewer, not yet acted on by the agent.
    public var awaitingAgent: Bool { status != .pending && handledAt == nil }

    /// The sizes the check is answered at: its own, or the one `default` size.
    public var effectiveSizes: [CheckSize] {
        sizes.isEmpty ? [CheckSize(id: CheckSize.defaultID, label: "Default")] : sizes
    }

    /// Every key the results are stored under: each size, or each size × appearance.
    public var resultKeys: [String] {
        let ids = effectiveSizes.map(\.id)
        guard !appearance.isEmpty else { return ids }
        return ids.flatMap { size in appearance.map { "\(size).\($0.rawValue)" } }
    }

    public static func resultKey(size: String, appearance: CheckAppearance?) -> String {
        appearance.map { "\(size).\($0.rawValue)" } ?? size
    }

    /// Where a screenshot at `key` goes, relative to the request folder.
    public static func screenshotPath(check: String, key: String) -> String { "results/\(check)-\(key).png" }

    /// How many lines are answered at a key, of how many.
    public func progress(_ key: String) -> (answered: Int, total: Int) {
        let answers = results[key]?.answers ?? [:]
        return (checklist.filter { answers[$0.id] != nil }.count, checklist.count)
    }

    /// Every line answered fail or note, in key then checklist order (keys outside the check's
    /// own sizes, such as `custom`, after them in the order they sort).
    public var failures: [CheckFailure] {
        let own = resultKeys
        let keys = own + results.keys.filter { !own.contains($0) }.sorted()
        return keys.flatMap { key -> [CheckFailure] in
            guard let result = results[key] else { return [] }
            return checklist.compactMap { line in
                guard let answer = result.answers[line.id], answer.result != .pass else { return nil }
                return CheckFailure(size: key, item: line.id, text: line.text, result: answer.result, note: answer.note,
                                    screenshot: result.screenshot)
            }
        }
    }

    /// Whether only the machine serving the page can open it (`localhost`, `127.0.0.1`, `*.local`).
    public var isLocalOnly: Bool { Self.isLocalOnly(url) }

    public static func isLocalOnly(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}

extension Review {
    static func parseCheckSize(_ node: Node) -> CheckSize? {
        if let map = node.mapping {
            let width = positiveInt(map["width"]), height = positiveInt(map["height"])
            guard let id = string(map["id"]) ?? (width != nil && height != nil ? "\(width!)x\(height!)" : nil) else { return nil }
            let preset = CheckSize.presets.first { $0.id == id }
            var size = CheckSize(id: id, label: string(map["label"]) ?? preset?.label ?? id,
                                 ua: string(map["ua"]).flatMap(CheckUserAgent.init(rawValue:)) ?? preset?.ua ?? .default)
            if let w = width ?? preset?.width, let h = height ?? preset?.height { size.width = w; size.height = h }
            return size
        }
        guard let id = string(node) else { return nil }
        if let preset = CheckSize.presets.first(where: { $0.id == id.lowercased() }) { return preset }
        if let (w, h) = CheckSize.dimensions(id), id.range(of: #"^\d+x\d+$"#, options: .regularExpression) != nil {
            return CheckSize(id: id, label: id, width: w, height: h)
        }
        return CheckSize(id: id, label: id)
    }

    private static func positiveInt(_ node: Node?) -> Int? {
        guard let text = string(node), let value = Double(text), value > 0, value.isFinite else { return nil }
        return Int(value)
    }

    static func parseCheck(_ node: Node, index: Int) -> ReviewCheck? {
        guard let map = node.mapping, let url = string(map["url"]) else { return nil }
        let rawSizes: [Node] = map["sizes"].map { $0.sequence.map(Array.init) ?? [$0] } ?? []
        var appearance: [CheckAppearance] = []
        for raw in ids(map["appearance"]) {
            if let value = CheckAppearance(rawValue: raw.lowercased()), !appearance.contains(value) { appearance.append(value) }
        }
        let checklist: [CheckLine] = (map["checklist"]?.sequence.map(Array.init) ?? []).enumerated().compactMap { offset, entry in
            if let line = entry.mapping {
                guard let text = string(line["text"]) else { return nil }
                return CheckLine(id: string(line["id"]) ?? CheckLine.id(for: text, index: offset), text: text)
            }
            return string(entry).map { CheckLine(id: CheckLine.id(for: $0, index: offset), text: $0) }
        }
        var results: [String: CheckResult] = [:]
        for (key, value) in map["results"]?.mapping ?? [:] {
            guard let name = key.string, let entry = value.mapping else { continue }
            var answers: [String: CheckAnswer] = [:]
            for (lineKey, raw) in entry["answers"]?.mapping ?? [:] {
                guard let line = lineKey.string else { continue }
                let answer = raw.mapping
                guard let result = string(answer?["result"] ?? raw).flatMap(CheckAnswerResult.init(rawValue:)) else { continue }
                answers[line] = CheckAnswer(result: result, note: string(answer?["note"]), at: string(answer?["at"]))
            }
            results[name] = CheckResult(viewport: string(entry["viewport"]), by: string(entry["by"]), at: string(entry["at"]),
                                        screenshot: string(entry["screenshot"]), answers: answers)
        }
        return ReviewCheck(
            id: string(map["id"]) ?? "check-\(index + 1)",
            url: url,
            title: string(map["title"]),
            note: string(map["note"]),
            sizes: rawSizes.compactMap(parseCheckSize),
            appearance: appearance,
            checklist: checklist,
            revises: string(map["revises"]),
            actions: parseActions(map),
            results: results,
            status: string(map["status"]).flatMap(ReviewStatus.init(rawValue:)) ?? .pending,
            decidedBy: string(map["decided_by"]),
            decidedAt: string(map["decided_at"]),
            comments: parseComments(map["comments"]),
            handledAt: string(map["handled_at"])
        )
    }

    /// A list of ids: `[a, b]`, or a single `a`.
    static func ids(_ node: Node?) -> [String] {
        if let list = node?.sequence { return list.compactMap { string($0) } }
        return string(node).map { [$0] } ?? []
    }
}
