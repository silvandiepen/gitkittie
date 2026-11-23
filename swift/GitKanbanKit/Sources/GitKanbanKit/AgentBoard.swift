import Foundation
import GitKittieKit

// What an agent can do with one board, over any file source (a repository through the
// provider API, or a folder). It works on the card files as they are: the frontmatter keys
// an agent sets are written as given, every other line of a card is kept, and the board's
// own README decides lanes, statuses and the card template. Nothing here touches what the
// app has on screen.

/// Something a tool call cannot do, said in a way an agent can act on.
public struct AgentBoardError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A JSON value as a tool receives it, turned into the YAML it is written as.
public enum AgentFieldValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case list([String])

    /// From a decoded JSON value; `nil` for a shape a frontmatter field cannot hold.
    public init?(json: Any) {
        switch json {
        case is NSNull: self = .null
        case let number as NSNumber:
            // JSON booleans arrive as NSNumber too; CFBoolean tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.stringValue) }
        case let string as String: self = .string(string)
        case let array as [Any]:
            var items: [String] = []
            for item in array {
                if let string = item as? String { items.append(string) } else if let number = item as? NSNumber { items.append(number.stringValue) } else { return nil }
            }
            self = .list(items)
        default: return nil
        }
    }

    var yaml: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value
        case .string(let value): return Self.scalar(value)
        case .list(let items): return "[" + items.map(Self.scalar).joined(separator: ", ") + "]"
        }
    }

    /// Timestamps stay bare, as the board writes them; anything else is quoted when YAML needs it.
    private static func scalar(_ value: String) -> String {
        if value.range(of: #"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?)?$"#, options: .regularExpression) != nil { return value }
        return BoardStore.yamlScalar(value)
    }
}

/// Edits to the text of a card: top-level frontmatter keys and the activity log.
public enum AgentCardText {
    /// Set top-level frontmatter keys, keeping every other line. A key that held a block
    /// (a list written over several lines) loses those lines with it.
    public static func set(_ text: String, _ fields: [(key: String, value: AgentFieldValue)]) -> String {
        guard !fields.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        var end: Int
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            end = close
        } else {
            // No frontmatter yet: give the card one.
            lines = ["---", "---", ""] + lines
            end = 1
        }
        for (key, value) in fields {
            let line = "\(key): \(value.yaml)"
            if let index = (1..<end).first(where: { isKey(lines[$0], key) }) {
                var last = index + 1
                while last < end, isContinuation(lines[last]) { last += 1 }
                lines.replaceSubrange(index..<last, with: [line])
                end -= (last - index - 1)
            } else {
                lines.insert(line, at: end)
                end += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A top-level frontmatter value as written (unquoted), or `nil` when absent or null.
    public static func value(_ text: String, _ key: String) -> String? {
        guard let frontmatter = BoardMarkdown.splitFrontmatter(text).0 else { return nil }
        return BoardStore.lenientFields(frontmatter)[key] as? String
    }

    /// Add one entry to the end of the card's `## Activity log`, making the section if needed.
    public static func appendActivity(_ text: String, entry: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let item = "- " + entry.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard let heading = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## activity log" }) else {
            return (lines + ["", "## Activity log", "", item]).joined(separator: "\n") + "\n"
        }
        var insert = lines.count
        if let next = lines[(heading + 1)...].firstIndex(where: { $0.hasPrefix("## ") || $0.hasPrefix("# ") }) { insert = next }
        while insert > heading + 1, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
        var addition = [item]
        if insert == heading + 1 { addition.insert("", at: 0) }
        if insert < lines.count { addition.append("") }
        lines.insert(contentsOf: addition, at: insert)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isKey(_ line: String, _ key: String) -> Bool {
        guard let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") else { return false }
        return line[..<colon].trimmingCharacters(in: .whitespaces) == key
    }

    private static func isContinuation(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return first.isWhitespace || line.hasPrefix("- ")
    }
}

/// One board, for an agent.
public struct AgentBoard {
    let source: any BoardWritable
    /// The board's folder, relative to the source's root ("" = the root itself).
    let folder: String
    var now: () -> Date = Date.init
    /// Opens a linked docs folder in another repository; nil where there is no way to (a
    /// board in a plain folder, no connection).
    var linkedSource: (@Sendable (DocSource) async -> (any BoardWritable)?)?

    private func join(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: "/") }
    private var stamp: String { Review.timestamp(now()) }

    /// The products this board's README lists.
    func products() async -> [BoardProduct] {
        let path = folder.isEmpty ? "README.md" : "\(folder)/README.md"
        guard let readme = try? await source.readText(path) else { return [] }
        return BoardStore.products(inReadme: readme)
    }

    struct Shell {
        let project: BoardProject
        let config: EffectiveConfig
        let listing: BoardListing
    }

    func shell() async throws -> Shell {
        let loaded = try await RemoteBoardStore.loadBoardShell(source: source, folder: folder)
        guard !loaded.board.config.lanes.isEmpty else {
            throw AgentBoardError("This folder has no lanes, so it is not a board. Check the board's folder.")
        }
        return Shell(project: loaded.project, config: loaded.board.config, listing: loaded.listing)
    }

    // MARK: Reading

    /// The board's lanes and vocabulary: what a card's fields may be set to.
    public func describe() async throws -> [String: Any] {
        let shell = try await shell()
        let config = shell.config
        return [
            "name": shell.project.name,
            "folder": folder,
            "card_id_prefix": Self.prefix(in: shell.listing, fallback: shell.project.name, ignoring: Set(await products().compactMap(\.prefix))) as Any,
            "lanes": config.lanes.map { lane -> [String: Any] in
                ["id": lane.id, "name": lane.name, "status": lane.status, "cards": shell.listing.count(in: lane),
                 "backlog": lane.isBacklog, "terminal": lane.terminal == true]
            },
            "priorities": config.priorities.map(\.id),
            "types": config.types,
            "epics": config.epics.map { ["id": $0.id, "name": $0.name ?? $0.id] },
            "users": config.users.map { ["id": $0.id, "name": $0.name ?? $0.id] },
            "products": await products().map { product -> [String: Any] in
                var out: [String: Any] = ["id": product.id, "name": product.name]
                out["card_id_prefix"] = product.prefix
                return out
            },
        ]
    }

    /// Extra rule files a repository or a board may carry next to its README.
    static let ruleFiles = ["AGENTS.md", "RULES.md"]

    /// Everything written down about how to work on this board, most general first: the
    /// repository's contract (the README next to `TASK_TEMPLATE.md`, found from the board's
    /// folder upwards) and its rule files, the card template, then the board's own README
    /// and rule files. Where they disagree, the board's own rules win over the repository's.
    public func rules() async throws -> [String: Any] {
        var directory = folder
        var result: [String: Any] = [:]
        while true {
            if let template = try? await source.readText(join(directory, "TASK_TEMPLATE.md")) {
                result["template"] = template
                if let readme = try? await source.readText(join(directory, "README.md")) { result["contract"] = readme }
                for file in Self.ruleFiles where directory != folder {
                    if let text = try? await source.readText(join(directory, file)) { result["repository_\(file)"] = text }
                }
                break
            }
            guard let slash = directory.lastIndex(of: "/") else {
                if directory.isEmpty { break }
                directory = ""
                continue
            }
            directory = String(directory[..<slash])
        }
        if !folder.isEmpty || result["contract"] == nil, let own = try? await source.readText(join(folder, "README.md")) {
            result["board_readme"] = own
        }
        for file in Self.ruleFiles {
            if let text = try? await source.readText(join(folder, file)) { result["board_\(file)"] = text }
        }
        if result.isEmpty { throw AgentBoardError("This board has no README.md, rule file or TASK_TEMPLATE.md to read rules from.") }
        result["precedence"] = "The board's own files (board_*) win over the repository's (contract, repository_*). get_board lists the values fields may take."
        return result
    }

    /// Refuse values the board does not have: a card must use the board's own priorities,
    /// types, epics, users and statuses (its effective config), not free text.
    static func validate(_ fields: [(key: String, value: AgentFieldValue)], config: EffectiveConfig) throws {
        func check(_ key: String, allowed: [String], what: String) throws {
            guard !allowed.isEmpty, let field = fields.first(where: { $0.key == key }), case .string(let value) = field.value else { return }
            guard allowed.contains(value) else {
                throw AgentBoardError("\"\(value)\" is not one of this board's \(what). Use one of: \(allowed.joined(separator: ", ")). If it should exist, it has to be added to the board's README first.")
            }
        }
        try check("priority", allowed: config.priorities.map(\.id), what: "priorities")
        try check("type", allowed: config.types, what: "types")
        try check("epic", allowed: config.epics.map(\.id), what: "epics")
        try check("assignee", allowed: config.users.map(\.id), what: "users")
        try check("status", allowed: config.lanes.map(\.status), what: "statuses (move the card with \"lane\" instead of setting status)")
    }

    /// Every text file of a lane, in as few round trips as the source allows.
    private func texts(in directory: String, names: [String]) async throws -> [String: String] {
        var texts = await (source as? any BulkTextSource)?.readTexts(in: directory) ?? [:]
        let missing = names.filter { texts[$0] == nil }
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            for name in missing {
                group.addTask { (name, try await source.readText("\(directory)/\(name)")) }
            }
            for try await (name, text) in group { texts[name] = text }
        }
        return texts
    }

    private static let summaryKeys = ["id", "title", "status", "priority", "type", "epic", "product", "assignee",
                                      "picked_up_by", "claim_expires_at", "blocked", "updated_at"]

    private func summary(_ text: String, fileName: String, lane: Lane) -> [String: Any] {
        let fields = BoardMarkdown.splitFrontmatter(text).0.map { BoardStore.lenientFields($0) } ?? [:]
        var summary: [String: Any] = ["file": fileName, "lane": lane.name, "lane_id": lane.id]
        for key in Self.summaryKeys { if let value = fields[key] as? String { summary[key] = value } }
        if summary["title"] == nil { summary["title"] = BoardStore.parseCard(text: text, fileName: fileName, fieldSource: nil).fields.title }
        if summary["id"] == nil { summary["id"] = String(fileName.dropLast(fileName.hasSuffix(".md") ? 3 : 0)) }
        return summary
    }

    /// Cards with their main fields. `lane` is a lane id, name or status; `query` matches
    /// id and title; `assignee` matches the assignee or the claimant.
    public func listCards(lane: String? = nil, query: String? = nil, assignee: String? = nil, limit: Int = 200) async throws -> [[String: Any]] {
        let shell = try await shell()
        var lanes = shell.config.lanes.filter { !$0.folder.isEmpty }
        if let lane, !lane.isEmpty { lanes = [try Self.lane(lane, in: shell.config)] }
        var cards: [[String: Any]] = []
        for lane in lanes {
            let names = (shell.listing.files[lane.id] ?? []).sorted()
            guard !names.isEmpty else { continue }
            let texts = try await texts(in: join(folder, lane.folder), names: names)
            for name in names {
                guard let text = texts[name] else { continue }
                cards.append(summary(text, fileName: name, lane: lane))
            }
        }
        if let query = query?.lowercased(), !query.isEmpty {
            cards = cards.filter { card in
                [card["id"], card["title"], card["file"]].contains { ($0 as? String)?.lowercased().contains(query) == true }
            }
        }
        if let assignee = assignee?.lowercased(), !assignee.isEmpty {
            cards = cards.filter { ($0["assignee"] as? String)?.lowercased() == assignee || ($0["picked_up_by"] as? String)?.lowercased() == assignee }
        }
        return Array(cards.prefix(max(1, limit)))
    }

    struct Found {
        let lane: Lane
        let fileName: String
        let path: String
        let text: String
        var id: String { AgentCardText.value(text, "id") ?? String(fileName.dropLast(fileName.hasSuffix(".md") ? 3 : 0)) }
    }

    /// A card by its id (`PETS-12`) or file name.
    func find(_ card: String, in shell: Shell) async throws -> Found {
        let wanted = card.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { throw AgentBoardError("Say which card: its id or file name.") }
        var matches: [(Lane, String)] = []
        for lane in shell.config.lanes where !lane.folder.isEmpty {
            for name in shell.listing.files[lane.id] ?? [] {
                let lower = name.lowercased()
                if lower == wanted || lower == wanted + ".md" || lower.hasPrefix(wanted + "-") { matches.append((lane, name)) }
            }
        }
        if matches.count > 1 {
            throw AgentBoardError("\"\(card)\" matches more than one card: \(matches.map(\.1).joined(separator: ", ")). Use the full file name.")
        }
        guard let (lane, fileName) = matches.first else {
            throw AgentBoardError("No card \"\(card)\" on this board. Use list_cards to see what is there.")
        }
        let path = join(folder, lane.folder, fileName)
        return Found(lane: lane, fileName: fileName, path: path, text: try await source.readText(path))
    }

    /// A card's whole text, where it is, and what is attached to it.
    public func getCard(_ card: String) async throws -> [String: Any] {
        let shell = try await shell()
        let found = try await find(card, in: shell)
        let attachments = ((try? await source.list(join(folder, "attachments", found.id))) ?? [])
            .filter { $0.kind == .file }.map(\.name).sorted()
        return ["id": found.id, "file": found.fileName, "path": found.path, "lane": found.lane.name,
                "lane_id": found.lane.id, "text": found.text, "attachments": attachments]
    }

    // MARK: Writing

    static func lane(_ wanted: String, in config: EffectiveConfig) throws -> Lane {
        let key = wanted.trimmingCharacters(in: .whitespaces).lowercased()
        let lanes = config.lanes.filter { !$0.folder.isEmpty }
        if let lane = lanes.first(where: { $0.id.lowercased() == key || $0.name.lowercased() == key || $0.status.lowercased() == key || $0.folder.lowercased() == key }) {
            return lane
        }
        throw AgentBoardError("No lane \"\(wanted)\". The lanes are: \(lanes.map { "\($0.name) (\($0.status))" }.joined(separator: ", ")).")
    }

    /// The id prefix the board's cards use (`PETS` for `PETS-12-…`): the most common one.
    static func prefix(in listing: BoardListing, fallback: String, ignoring: Set<String> = []) -> String? {
        prefix(among: listing.files.values.joined(), fallback: fallback, ignoring: ignoring)
    }

    /// The board's own id prefix: the one most of its tasks use. `ignoring` are prefixes
    /// that belong to products, which number their tasks apart from the board's.
    static func prefix(among fileNames: some Sequence<String>, fallback: String, ignoring: Set<String> = []) -> String? {
        var counts: [String: Int] = [:]
        for name in fileNames {
            if let match = name.range(of: #"^[A-Z][A-Z0-9]*(?=-\d+)"#, options: .regularExpression), !ignoring.contains(String(name[match])) {
                counts[String(name[match]), default: 0] += 1
            }
        }
        if let common = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key { return common }
        let letters = fallback.uppercased().filter { $0.isLetter || $0.isNumber }
        return letters.isEmpty ? nil : letters
    }

    /// The next unused id for `prefix`, numbered as wide as the board's existing ids.
    static func nextID(prefix: String, in listing: BoardListing) -> String {
        nextID(prefix: prefix, among: listing.files.values.joined())
    }

    static func nextID(prefix: String, among fileNames: some Sequence<String>) -> String {
        var highest = 0
        var width = 3
        for name in fileNames where name.hasPrefix(prefix + "-") {
            let digits = name.dropFirst(prefix.count + 1).prefix { $0.isNumber }
            if let number = Int(digits) {
                highest = max(highest, number)
                width = max(width, digits.count)
            }
        }
        let number = String(highest + 1)
        return prefix + "-" + String(repeating: "0", count: max(0, width - number.count)) + number
    }

    /// The file a new card titled `title` gets: `PETS-013-fix-the-door.md`.
    static func fileName(id: String, title: String) -> String {
        let slug = slug(title)
        return slug.isEmpty ? "\(id).md" : "\(id)-\(slug).md"
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let parts = String(mapped).split(separator: "-").prefix(10)
        return String(parts.joined(separator: "-").prefix(70))
    }

    /// Make a card from the board's template. Returns its id, file and lane.
    public func createCard(title rawTitle: String, lane wantedLane: String?, body: String?,
                           fields: [(key: String, value: AgentFieldValue)], createdBy: String) async throws -> [String: Any] {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AgentBoardError("A card needs a title.") }
        let shell = try await shell()
        let lanes = shell.config.lanes.filter { !$0.folder.isEmpty }
        let lane = try wantedLane.map { try Self.lane($0, in: shell.config) }
            ?? lanes.first { $0.status == "todo" } ?? lanes.first { !$0.isBacklog } ?? lanes[0]
        // A task for a product that numbers its own tasks takes that prefix.
        let known = await products()
        guard let prefix = Self.prefix(in: shell.listing, fallback: shell.project.name, ignoring: Set(known.compactMap(\.prefix))) else {
            throw AgentBoardError("Could not work out an id prefix for this board.")
        }
        try Self.validate(fields, config: shell.config)
        var ownPrefix: String?
        if let field = fields.first(where: { $0.key == "product" }), case .string(let wanted) = field.value {
            guard let product = known.first(where: { $0.id == wanted }) else {
                throw AgentBoardError("\"\(wanted)\" is not one of this board's products. Use one of: \(known.map(\.id).joined(separator: ", ")).")
            }
            ownPrefix = product.prefix
        }
        let id = Self.nextID(prefix: ownPrefix ?? prefix, in: shell.listing)
        let fileName = Self.fileName(id: id, title: title)
        let heading = "# \(title)"

        var text: String
        if let template = try? await rules()["template"] as? String {
            let (frontmatter, templateBody) = BoardMarkdown.splitFrontmatter(template)
            var bodyLines = templateBody.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            if bodyLines.first?.hasPrefix("# ") == true { bodyLines[0] = heading } else { bodyLines.insert(contentsOf: [heading, ""], at: 0) }
            let cardBody = body.map { "\(heading)\n\n\($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? bodyLines.joined(separator: "\n")
            text = "---\n\(frontmatter ?? "")\n---\n\n\(cardBody)\n"
        } else {
            text = "---\n---\n\n\(heading)\n\n\(body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")\n"
        }
        let folderName = folder.split(separator: "/").last.map(String.init) ?? shell.project.name
        var all: [(key: String, value: AgentFieldValue)] = [
            ("id", .string(id)), ("title", .string(title)), ("project", .string(folderName)), ("status", .string(lane.status)),
            ("created_by", .string(createdBy)), ("created_at", .string(stamp)), ("updated_at", .string(stamp)),
        ]
        // The caller's fields come last, except for what makes the card this card.
        all += fields.filter { !["id", "status"].contains($0.key) }
        text = AgentCardText.set(text, all)
        text = AgentCardText.appendActivity(text, entry: "\(stamp) — `\(createdBy)` created the card.")
        let path = join(folder, lane.folder, fileName)
        try await source.write(path: path, text: text, message: "chore(tasks): add \(id)")
        return ["id": id, "file": fileName, "path": path, "lane": lane.name]
    }

    /// Change a card's fields, replace its body, add an activity entry, and/or move it to
    /// another lane (which also sets `status`). `updated_at` is set unless given.
    public func updateCard(_ card: String, fields: [(key: String, value: AgentFieldValue)] = [], body: String? = nil,
                           lane wantedLane: String? = nil, activity: String? = nil, agent: String,
                           message: String? = nil) async throws -> [String: Any] {
        let shell = try await shell()
        let found = try await find(card, in: shell)
        let lane = try wantedLane.map { try Self.lane($0, in: shell.config) } ?? found.lane
        let moved = lane.id != found.lane.id
        guard !fields.isEmpty || body != nil || moved || activity?.isEmpty == false else {
            throw AgentBoardError("Nothing to change: give fields, body, lane or activity.")
        }
        if fields.contains(where: { $0.key == "id" }) { throw AgentBoardError("A card's id cannot be changed.") }
        try Self.validate(fields, config: shell.config)
        if let status = fields.first(where: { $0.key == "status" }), case .string(let value) = status.value, value != lane.status {
            throw AgentBoardError("status \"\(value)\" does not match the lane \(lane.name) (\(lane.status)). Move the card with \"lane\"; its status follows.")
        }

        var text = found.text
        if let body {
            let frontmatter = BoardMarkdown.splitFrontmatter(text).0 ?? ""
            text = "---\n\(frontmatter)\n---\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        var all = fields
        if moved, !all.contains(where: { $0.key == "status" }) { all.append(("status", .string(lane.status))) }
        if !all.contains(where: { $0.key == "updated_at" }) { all.append(("updated_at", .string(stamp))) }
        text = AgentCardText.set(text, all)
        if let activity, !activity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = AgentCardText.appendActivity(text, entry: "\(stamp) — `\(agent)` \(activity)")
        }
        let path = join(folder, lane.folder, found.fileName)
        let subject = message ?? (moved ? "chore(tasks): move \(found.id) to \(lane.name.lowercased())" : "chore(tasks): update \(found.id)")
        try await source.write(path: path, text: text, message: subject)
        if moved { try await source.delete(path: found.path, message: subject) }
        return ["id": found.id, "file": found.fileName, "path": path, "lane": lane.name, "moved": moved]
    }

    /// Claim a card for `agent`: refused when someone else holds an unexpired claim.
    public func claimCard(_ card: String, agent: String, hours: Double = 24, branch: String? = nil) async throws -> [String: Any] {
        let shell = try await shell()
        let found = try await find(card, in: shell)
        if let owner = AgentCardText.value(found.text, "picked_up_by"), !owner.isEmpty, owner != agent {
            let expiry = AgentCardText.value(found.text, "claim_expires_at")
            let expired = expiry.flatMap { ISO8601DateFormatter().date(from: $0) }.map { $0 < now() } ?? false
            if !expired {
                throw AgentBoardError("\(found.id) is already claimed by \(owner)\(expiry.map { " until \($0)" } ?? ""). Choose another card.")
            }
        }
        let progress = shell.config.lanes.first { $0.status == "in-progress" }
            ?? shell.config.lanes.first { $0.name.lowercased().contains("progress") }
        var fields: [(key: String, value: AgentFieldValue)] = [
            ("picked_up_by", .string(agent)), ("picked_up_at", .string(stamp)), ("last_heartbeat_at", .string(stamp)),
            ("claim_expires_at", .string(Review.timestamp(now().addingTimeInterval(hours * 3600)))),
        ]
        if let branch, !branch.isEmpty { fields.append(("working_branch", .string(branch))) }
        return try await updateCard(found.fileName, fields: fields, lane: progress?.id, activity: "claimed the card.",
                                    agent: agent, message: "chore(tasks): claim \(found.id)")
    }

    /// Attach a file (a screenshot) to a card.
    public func attach(_ card: String, fileName: String, data: Data) async throws -> [String: Any] {
        let shell = try await shell()
        let found = try await find(card, in: shell)
        let safe = String(fileName.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
        guard !safe.trimmingCharacters(in: CharacterSet(charactersIn: ".-")).isEmpty else { throw AgentBoardError("Give the attachment a file name.") }
        guard !data.isEmpty else { throw AgentBoardError("The attachment is empty.") }
        let path = join(folder, "attachments", found.id, safe)
        try await source.writeData(path: path, data: data, message: "chore(tasks): attach \(safe) to \(found.id)")
        return ["id": found.id, "path": path, "bytes": data.count]
    }
}

/// Making a new board in a repository that already holds boards.
public enum AgentBoardFactory {
    /// A board name as a folder name: one path component, nothing hidden.
    static func folderName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), name != "attachments", name != "review",
              name.count <= 60 else {
            throw AgentBoardError("\"\(raw)\" cannot be a board name. Use a short name without slashes, like the project's name.")
        }
        return name
    }

    /// Create `<parent>/<name>` as a board that inherits the repository's lanes: its
    /// README, and one folder per lane. Returns the board's folder and lane names.
    ///
    /// `lanePlaceholders`: a git repository keeps no empty folders, so there each lane gets a
    /// `.gitkeep`, as the existing boards have. A folder source refuses dot-files (and needs
    /// none: a lane folder appears with its first card), so there they are left out.
    static func create(source: any BoardWritable, parent: String, name rawName: String,
                       description: String?, agent: String, lanePlaceholders: Bool) async throws -> (folder: String, lanes: [String]) {
        let name = try folderName(rawName)
        let folder = parent.isEmpty ? name : "\(parent)/\(name)"
        let siblings = (try? await source.list(parent)) ?? []
        if let existing = siblings.first(where: { $0.name.lowercased() == name.lowercased() }) {
            throw AgentBoardError("\(parent.isEmpty ? "" : parent + "/")\(existing.name) already exists. Use that board, or pick another name.")
        }
        // The lanes the new board inherits: no lanes means this repository has no board contract.
        let shell = try await RemoteBoardStore.loadBoardShell(source: source, folder: folder)
        let lanes = shell.board.config.lanes.filter { !$0.folder.isEmpty }
        guard !lanes.isEmpty else {
            throw AgentBoardError("This repository has no board contract with lanes above \(folder), so a new board would have none.")
        }
        let about = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let readme = """
        ---
        config: project
        project: \(BoardStore.yamlScalar(name))
        # Lanes: leave empty to inherit the root board lanes.
        lanes: []
        # The lists below extend the root vocabulary for this project; leave empty to inherit.
        users: []
        epics: []
        types: []
        priorities: []
        tags: []
        ---

        # \(name) board

        \(about.isEmpty ? "Work for \(name)." : about) Inherits the shared board contract.

        Created by `\(agent)`.

        """
        let message = "chore(tasks): add the \(name) board"
        try await source.write(path: "\(folder)/README.md", text: readme, message: message)
        for lane in lanes where lanePlaceholders {
            try await source.write(path: "\(folder)/\(lane.folder)/.gitkeep", text: "", message: message)
        }
        return (folder, lanes.map(\.name))
    }
}
