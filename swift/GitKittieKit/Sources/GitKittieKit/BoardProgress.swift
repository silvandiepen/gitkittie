import Foundation

/// The board folded into three stages so agent work can be followed at a glance.
/// Mirrors `packages/gitkanban-core/src/progress.ts`.
///
/// - `pipeline`: lanes before the in-progress lane (To do, Backlog)
/// - `working`: the in-progress lane
/// - `checkedOff`: lanes after it (In Review, Testing, Done) and any terminal lane
///
/// A checked-off card is unread until the reviewer marks it read (`read_at`), and unread
/// again once it's updated after that (`updated_at` > `read_at`).
public enum ProgressStage: String, CaseIterable, Sendable, Identifiable {
    case working, pipeline, checkedOff

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .working: "Working on"
        case .pipeline: "Up next"
        case .checkedOff: "Checked off"
        }
    }
}

public struct ProgressGroup: Equatable, Sendable, Identifiable {
    public var stage: ProgressStage
    /// Each card with the lane it sits in.
    public var entries: [ProgressEntry]
    public var id: String { stage.id }
}

public struct ProgressEntry: Equatable, Sendable, Identifiable {
    public var card: Card
    public var lane: Lane
    public var id: String { card.id }
}

public enum BoardProgress {

    public static func stage(for lane: Lane, in lanes: [Lane]) -> ProgressStage {
        if lane.terminal == true { return .checkedOff }
        let index = lanes.firstIndex { $0.id == lane.id }
        if let index, let progress = lanes.firstIndex(where: isProgressLane) {
            if index < progress { return .pipeline }
            if index == progress { return .working }
            return .checkedOff
        }
        // No recognisable in-progress lane: the first lane is the queue, the last is done.
        guard let index, index > 0 else { return .pipeline }
        return index == lanes.count - 1 ? .checkedOff : .working
    }

    private static func isProgressLane(_ lane: Lane) -> Bool {
        let text = "\(lane.id) \(lane.status) \(lane.name)".lowercased()
        return text.contains("progress") || text.split(whereSeparator: { !$0.isLetter }).contains("doing")
    }

    /// Group a board's columns into stages, in `ProgressStage.allCases` order. Lane order is
    /// kept for working and pipeline; checked off puts unread cards first, newest first.
    /// `lanes` is the board's configured lane order (defaults to the columns' order); pass it
    /// when the columns were reordered for display.
    public static func groups(_ columns: [Column], lanes configured: [Lane]? = nil) -> [ProgressGroup] {
        let lanes = configured ?? columns.map(\.lane)
        var byStage: [ProgressStage: [ProgressEntry]] = [:]
        for column in columns {
            let stage = stage(for: column.lane, in: lanes)
            byStage[stage, default: []] += column.cards.map { ProgressEntry(card: $0, lane: column.lane) }
        }
        if let done = byStage[.checkedOff] {
            byStage[.checkedOff] = done.enumerated().sorted { a, b in
                let ua = isUnread(a.element.card.fields), ub = isUnread(b.element.card.fields)
                if ua != ub { return ua }
                let ta = date(a.element.card.fields.updatedAt), tb = date(b.element.card.fields.updatedAt)
                if ta != tb { return (ta ?? .distantPast) > (tb ?? .distantPast) }
                return a.offset < b.offset
            }.map(\.element)
        }
        return ProgressStage.allCases.map { ProgressGroup(stage: $0, entries: byStage[$0] ?? []) }
    }

    /// Whether a checked-off card still needs reading: never read, or updated since.
    public static func isUnread(_ fields: CardFields) -> Bool {
        guard let read = date(fields.readAt) else { return true }
        guard let updated = date(fields.updatedAt) else { return false }
        return updated > read
    }

    /// The newest entry of a card's `## Activity log` (entries are appended), without its bullet.
    public static func latestActivity(_ body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            return (trimmed.hasPrefix("## ") || trimmed.hasPrefix("### "))
                && trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) == "activity log"
        }) else { return nil }
        var latest: String?
        for line in lines[(start + 1)...] {
            if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let text = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { latest = text }
            }
        }
        return latest
    }

    /// Parse an ISO-8601 timestamp as written on cards (with or without fractional seconds).
    public static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
