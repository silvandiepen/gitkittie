import Foundation
import TasksAgentTools

/// Shows the app's answers to a person: aligned tables, readable cards.
public struct Renderer: Sendable {
    /// The terminal's width; nil when output is not a terminal (nothing is cut short then).
    public var width: Int?

    public init(width: Int?) { self.width = width }

    public func render(_ view: Plan.View, _ value: Any, plan: Plan) -> String {
        switch view {
        case .boards: return boards(value)
        case .board: return board(value)
        case .rules: return rules(value)
        case .cards: return cards(value, showBoard: plan.board == .all)
        case .card: return card(value)
        case .created: return change("Created", value)
        case .updated: return change("Updated", value)
        case .moved: return change("Moved", value)
        case .claimed: return change("Claimed", value)
        case .commented: return change("Logged on", value)
        case .attached:
            let object = value as? [String: Any] ?? [:]
            return "Attached \(object["path"] as? String ?? "the file") (\(object["bytes"] as? Int ?? 0) bytes) to \(object["id"] as? String ?? "the card")."
        case .reviews: return reviews(value, showBoard: plan.board == .all)
        case .review(let id): return review(id, value)
        case .handled: return "Handled. " + compact(value)
        case .closed:
            let object = value as? [String: Any] ?? [:]
            return "Closed review request \(object["request"] as? String ?? "")."
        case .docs: return docs(value)
        case .doc: return doc(value)
        case .docHits: return docHits(value)
        case .boardCreated:
            let object = value as? [String: Any] ?? [:]
            let lanes = (object["lanes"] as? [String] ?? []).joined(separator: ", ")
            return "Created board \(object["board"] as? String ?? "") (lanes: \(lanes))."
        case .raw: return Self.pretty(value)
        case .reviewCreated: return reviewCreated(value)
        case .reviewFile: return Self.pretty(value)
        }
    }

    // MARK: Pieces

    public static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    private func compact(_ value: Any) -> String {
        guard let object = value as? [String: Any] else { return "" }
        return object.keys.sorted().map { "\($0): \(text(object[$0]))" }.joined(separator: ", ")
    }

    func text(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "yes" : "no" }
            return number.stringValue
        case let list as [Any]: return list.map { text($0) }.joined(separator: ", ")
        default: return "\(value!)"
        }
    }

    /// An aligned table; the last column that can shrink (`flex`) is cut to fit the terminal.
    func table(_ headers: [String], _ rows: [[String]], flex: Int? = nil) -> String {
        guard !rows.isEmpty else { return "" }
        var widths = headers.indices.map { column in ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0 }
        if let width, let flex {
            let others = widths.enumerated().filter { $0.offset != flex }.map(\.element).reduce(0, +) + 2 * (headers.count - 1)
            widths[flex] = max(12, min(widths[flex], width - others))
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { column, cell in
                var cell = cell.replacingOccurrences(of: "\n", with: " ")
                if cell.count > widths[column] { cell = String(cell.prefix(max(1, widths[column] - 1))) + "…" }
                return column == cells.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        return ([line(headers)] + rows.map(line)).joined(separator: "\n")
    }

    /// `key  value` lines, keys aligned.
    func pairs(_ items: [(String, String)]) -> String {
        let width = (items.map(\.0.count).max() ?? 0) + 2
        return items.map { "\(($0.0 + ":").padding(toLength: width, withPad: " ", startingAt: 0))\($0.1)" }.joined(separator: "\n")
    }

    // MARK: Boards

    func boards(_ value: Any) -> String {
        let boards = value as? [[String: Any]] ?? []
        guard !boards.isEmpty else { return "No boards yet. Add a board in the Tasks app." }
        let rows = boards.map { [text($0["board"]), text($0["name"]), text($0["source"]), ($0["in_app_sidebar"] as? Bool ?? false) ? "yes" : "no"] }
        return table(["BOARD", "NAME", "SOURCE", "IN SIDEBAR"], rows)
    }

    func board(_ value: Any) -> String {
        let board = value as? [String: Any] ?? [:]
        var prefixes = [text(board["card_id_prefix"])].filter { !$0.isEmpty }
        let products = board["products"] as? [[String: Any]] ?? []
        prefixes += products.compactMap { product in
            (product["card_id_prefix"] as? String).map { "\($0) (\(text(product["name"])))" }
        }
        var out = pairs([
            ("Board", "\(text(board["name"])) (\(text(board["folder"])))"),
            ("Card ids", prefixes.joined(separator: ", ")),
            ("Priorities", text(board["priorities"])),
            ("Types", text(board["types"])),
            ("Epics", (board["epics"] as? [[String: Any]] ?? []).map { text($0["id"]) }.joined(separator: ", ")),
            ("Users", (board["users"] as? [[String: Any]] ?? []).map { text($0["id"]) }.joined(separator: ", ")),
        ].filter { !$0.1.isEmpty })
        let lanes = (board["lanes"] as? [[String: Any]] ?? []).map { lane in
            [text(lane["id"]), text(lane["name"]), text(lane["status"]), text(lane["cards"])]
        }
        if !lanes.isEmpty { out += "\n\n" + table(["LANE", "NAME", "STATUS", "CARDS"], lanes) }
        return out
    }

    func rules(_ value: Any) -> String {
        let rules = value as? [String: Any] ?? [:]
        let first = ["contract", "template"]
        let order = first.filter { rules[$0] != nil }
            + rules.keys.filter { $0.hasPrefix("repository_") }.sorted()
            + ["board_readme"].filter { rules[$0] != nil }
            + rules.keys.filter { $0.hasPrefix("board_") && $0 != "board_readme" }.sorted()
        let rest = rules.keys.filter { !order.contains($0) }.sorted()
        return (order + rest).map { key in
            "━━ \(key) ━━\n\n" + text(rules[key]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n")
    }

    // MARK: Cards

    func cards(_ value: Any, showBoard: Bool) -> String {
        let cards = value as? [[String: Any]] ?? []
        guard !cards.isEmpty else { return "No cards." }
        var headers = ["ID", "LANE", "PRI", "OWNER", "UPDATED", "TITLE"]
        if showBoard { headers.insert("BOARD", at: 0) }
        let rows = cards.map { card -> [String] in
            let owner = text(card["picked_up_by"]).isEmpty ? text(card["assignee"]) : text(card["picked_up_by"])
            var row = [text(card["id"]), text(card["lane"]), text(card["priority"]), owner,
                       String(text(card["updated_at"]).prefix(10)), text(card["title"])]
            if ["true", "yes"].contains(text(card["blocked"])) { row[5] = "[blocked] " + row[5] }
            if showBoard { row.insert(text(card["board"]), at: 0) }
            return row
        }
        return table(headers, rows, flex: headers.count - 1) + "\n\n\(cards.count) card\(cards.count == 1 ? "" : "s")"
    }

    /// A card: the fields that are set, aligned, then its body.
    func card(_ value: Any) -> String {
        let card = value as? [String: Any] ?? [:]
        let full = text(card["text"])
        let (frontmatter, body) = Self.split(full)
        var fields: [(String, String)] = []
        var title = ""
        for (key, raw) in frontmatter {
            let value = raw.trimmingCharacters(in: .whitespaces)
            if key == "title" { title = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")); continue }
            if key == "id" || ["null", "[]", "\"\"", "''", ""].contains(value) { continue }
            fields.append((key, value))
        }
        var head = "\(text(card["id"]))  \(title)\n"
        head += pairs([("lane", text(card["lane"])), ("path", text(card["path"]))] + fields)
        let attachments = card["attachments"] as? [String] ?? []
        if !attachments.isEmpty { head += "\n" + pairs([("attachments", attachments.joined(separator: ", "))]) }
        return head + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Frontmatter as (key, value) in order (a list or block value folded onto one line), and the body.
    static func split(_ text: String) -> ([(String, String)], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([], text)
        }
        var pairs: [(String, String)] = []
        for line in lines[1..<end] {
            if let first = line.first, first == " " || first == "-" || first == "\t" {
                guard !pairs.isEmpty else { continue }
                let item = line.trimmingCharacters(in: .whitespaces)
                let cleaned = item.hasPrefix("- ") ? String(item.dropFirst(2)) : item
                pairs[pairs.count - 1].1 += pairs[pairs.count - 1].1.isEmpty ? cleaned : ", " + cleaned
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            pairs.append((String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        return (pairs, lines[(end + 1)...].joined(separator: "\n"))
    }

    func change(_ verb: String, _ value: Any) -> String {
        let object = value as? [String: Any] ?? [:]
        let id = text(object["id"])
        let lane = text(object["lane"])
        switch verb {
        case "Created": return "Created \(id) in \(lane) (\(text(object["path"])))."
        case "Moved": return "Moved \(id) to \(lane)."
        case "Claimed": return "Claimed \(id) (\(lane))."
        default:
            let moved = (object["moved"] as? Bool) == true
            return "\(verb) \(id)" + (moved ? ", moved to \(lane)." : " (\(lane)).")
        }
    }

    // MARK: Reviews

    func reviews(_ value: Any, showBoard: Bool) -> String {
        let requests = value as? [[String: Any]] ?? []
        guard !requests.isEmpty else { return "Nothing to handle." }
        var headers = ["REQUEST", "CARD", "PENDING", "TO HANDLE", "TITLE"]
        if showBoard { headers.insert("BOARD", at: 0) }
        let rows = requests.map { request -> [String] in
            var row = [text(request["request"]), text(request["card"]), text(request["pending"]), text(request["to_handle"]), text(request["title"])]
            if showBoard { row.insert(text(request["board"]), at: 0) }
            return row
        }
        return table(headers, rows, flex: headers.count - 1)
    }

    func review(_ id: String, _ value: Any) -> String {
        let requests = value as? [[String: Any]] ?? []
        guard let request = requests.first(where: { text($0["request"]).lowercased() == id.lowercased() }) else {
            return "No review request \"\(id)\" on this board."
        }
        var out = "\(text(request["request"]))  \(text(request["title"]))\n"
        func actions(_ object: [String: Any]) -> [(String, String)] {
            ["on_accept", "on_changes", "on_reject"].compactMap { key in
                guard let list = object[key] as? [[String: Any]], !list.isEmpty else { return nil }
                return (key.replacingOccurrences(of: "_", with: " "), list.map { action in
                    var words = [text(action["move"]).isEmpty ? "→ \(text(action["to"]))" : "\(text(action["move"])) → \(text(action["to"]))"]
                    if (action["comment"] as? Bool) == true { words.append("with comments") }
                    if !text(action["assign"]).isEmpty { words.append("assign \(text(action["assign"]))") }
                    return words.joined(separator: ", ")
                }.joined(separator: "; "))
            }
        }
        out += pairs(([("card", text(request["card"])), ("asks", text(request["question"])), ("for", text(request["for"])), ("due", text(request["due"])),
                       ("requested by", text(request["requested_by"])), ("requested at", text(request["requested_at"])), ("notify", text(request["notify"])),
                       ("pending", text(request["pending"])), ("to handle", text(request["to_handle"])), ("outcome", text(request["outcome"]))]
                      + actions(request))
            .filter { !$0.1.isEmpty })
        let items = request["items"] as? [[String: Any]] ?? []
        if !items.isEmpty {
            out += "\n\nItems:\n" + table(["ID", "KIND", "STATUS", "TO HANDLE", "FILE"], items.map {
                [text($0["id"]), text($0["kind"]), text($0["status"]), text($0["to_handle"]), text($0["file"])]
            }, flex: 4)
        }
        for question in request["questions"] as? [[String: Any]] ?? [] {
            out += "\n\nQuestion \(text(question["id"])): \(text(question["question"])) [\(text(question["status"]))]"
            for option in question["options"] as? [[String: Any]] ?? [] {
                let chosen = (question["answer"] as? [String] ?? []).contains(text(option["id"]))
                out += "\n  \(chosen ? "●" : "○") \(text(option["id"])): \(text(option["label"]))"
            }
            if let other = question["answer_other"] as? String { out += "\n  ● other: \(other)" }
        }
        for check in request["checks"] as? [[String: Any]] ?? [] {
            let sizes = (check["sizes"] as? [[String: Any]] ?? []).map { text($0["id"]) }
            out += "\n\nCheck \(text(check["id"])): \(text(check["url"])) [\(text(check["status"]))]"
            if !sizes.isEmpty { out += "\n  sizes: \(sizes.joined(separator: ", "))" }
            for line in check["checklist"] as? [[String: Any]] ?? [] { out += "\n  ☐ \(text(line["id"])): \(text(line["text"]))" }
            for failure in check["failed"] as? [[String: Any]] ?? [] {
                let note = text(failure["note"]).isEmpty ? "" : " — \(text(failure["note"]))"
                out += "\n  ✗ \(text(failure["size"])) \(text(failure["item"]))\(note)"
            }
        }
        let runs = request["actions_run"] as? [[String: Any]] ?? []
        if !runs.isEmpty {
            out += "\n\nActions run:\n" + table(["ON", "CARD", "FROM", "TO", "RESULT", "BY", "AT"], runs.map { run in
                let result = text(run["undone_at"]).isEmpty ? text(run["result"]) : "undone"
                return [text(run["on"]), text(run["card"]), text(run["from"]), text(run["to"]), result, text(run["by"]), text(run["at"])]
            }, flex: 4)
        }
        return out
    }

    func reviewCreated(_ value: Any) -> String {
        let object = value as? [String: Any] ?? [:]
        var out = "Asked for review: \(text(object["request"])) (\(text(object["folder"])))."
        for (key, word) in [("items", "files"), ("checks", "checks"), ("questions", "questions")] {
            let ids = object[key] as? [String] ?? []
            if !ids.isEmpty { out += "\n  \(word): \(ids.joined(separator: ", "))" }
        }
        if let assigned = object["for"] as? [String], !assigned.isEmpty { out += "\n  for: \(assigned.joined(separator: ", "))" }
        for warning in object["warnings"] as? [String] ?? [] { out += "\nwarning: \(warning)" }
        return out
    }

    // MARK: Docs

    func docs(_ value: Any) -> String {
        let docs = (value as? [String: Any])?["docs"] as? [[String: Any]] ?? []
        guard !docs.isEmpty else { return "No documentation pages." }
        return table(["PATH", "TITLE", "FROM"], docs.map { [text($0["path"]), text($0["title"]), text($0["from"])] }, flex: 1)
    }

    func doc(_ value: Any) -> String {
        let doc = value as? [String: Any] ?? [:]
        return "\(text(doc["path"]))  \(text(doc["title"]))\n\n" + text(doc["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func docHits(_ value: Any) -> String {
        let hits = (value as? [String: Any])?["hits"] as? [[String: Any]] ?? []
        guard !hits.isEmpty else { return "Nothing found." }
        return table(["PAGE", "LINE", "TEXT"], hits.map { ["\(text($0["path"]))", text($0["line_number"]), text($0["line"])] }, flex: 2)
    }

    // MARK: Tools

    public func tools(_ name: String?) throws -> String {
        if let name {
            guard let tool = AgentTools.all.first(where: { $0.name == name }) else {
                throw CLIError.usage("The app has no tool \"\(name)\". `tasks tools` lists them.")
            }
            let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) ?? [:]
            return "\(tool.name): \(tool.description)\n\nArguments (JSON Schema):\n" + Self.pretty(schema)
        }
        return table(["TOOL", "DESCRIPTION"], AgentTools.all.map { [$0.name, $0.description] }, flex: 1)
    }
}
