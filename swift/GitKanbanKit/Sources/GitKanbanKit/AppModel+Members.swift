import Foundation
import GitKittieKit

/// One value of a board folded into another (a member, a type, an epic, a priority):
/// every task that holds `from` in one of `fields` is rewritten to `into`.
public struct FieldMerge: Sendable, Equatable {
    public var fields: [String]
    public var from: String
    public var into: String
    public init(fields: [String], from: String, into: String) { self.fields = fields; self.from = from; self.into = into }

    /// A member: every field that names a person.
    public static func member(from: String, into: String) -> FieldMerge {
        FieldMerge(fields: AppModel.memberFields, from: from, into: into)
    }
}

extension AppModel {

    /// The frontmatter fields that name a person on a task. `created_by`, `read_by` and
    /// the like are history and stay as they were written.
    nonisolated static let memberFields = ["assignee", "picked_up_by", "reviewer", "testing_owner"]

    /// `text` with every one of `fields` that holds `from` set to `into`; nil when the
    /// card does not hold `from` there.
    static func replacingValue(in text: String, fields: [String] = memberFields, from: String, into: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var updates: [String: String?] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard fields.contains(key) else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            if value == from { updates[key] = into }
        }
        return updates.isEmpty ? nil : CardText.update(text, set: updates)
    }

    /// Rewrite every task on `project`'s board that holds a merged value, in all lanes.
    /// Returns how many tasks changed. A failure stops it and is left in `errorMessage`.
    @discardableResult
    public func mergeValues(_ merges: [FieldMerge], in project: BoardProject) async -> Int {
        let merges = merges.filter { !$0.from.isEmpty && !$0.into.isEmpty && $0.from != $0.into }
        guard let source, !merges.isEmpty else { return 0 }
        var changes: [String: String] = [:]
        do {
            settingsProgress = "Looking for tasks to update…"
            let listing = try await RemoteBoardStore.listing(source: source, folder: project.folder)
            for lane in listing.lanes where !lane.folder.isEmpty {
                let names = listing.files[lane.id] ?? []
                guard !names.isEmpty else { continue }
                let directory = project.folder.isEmpty ? lane.folder : "\(project.folder)/\(lane.folder)"
                let bulk = await (source as? any BulkTextSource)?.readTexts(in: directory)
                for name in names {
                    let path = "\(directory)/\(name)"
                    let original: String
                    if let known = bulk?[name] { original = known } else { original = try await source.readText(path) }
                    var text = original
                    for merge in merges {
                        if let next = Self.replacingValue(in: text, fields: merge.fields, from: merge.from, into: merge.into) { text = next }
                    }
                    if text != original { changes[path] = text }
                }
            }
            if !changes.isEmpty {
                let who = merges.map { "\($0.from) into \($0.into)" }.joined(separator: ", ")
                let message = "Merge \(who) on \(changes.count) task\(changes.count == 1 ? "" : "s")"
                settingsProgress = "Updating \(changes.count) task\(changes.count == 1 ? "" : "s")…"
                // One commit for all of them where the source can; otherwise one each.
                let asOne = try await (source as? any BatchWritable)?.writeTexts(changes, message: message) ?? false
                if !asOne {
                    for (index, change) in changes.sorted(by: { $0.key < $1.key }).enumerated() {
                        settingsProgress = "Updating tasks… \(index + 1) of \(changes.count)"
                        try await source.write(path: change.key, text: change.value, message: message)
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription }
        settingsProgress = nil
        return errorMessage == nil ? changes.count : 0
    }
}
