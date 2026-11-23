import Foundation
import Yams

/// Parsing board configuration and cards from markdown/YAML, and assembling a
/// board's columns. Mirrors the read path of `@gitkittie/gitkanban-core`.
public enum BoardStore {

    // MARK: Config parsing (from a README's YAML frontmatter)

    /// Parse a root `BoardConfig` from a YAML string (a `Tasks/README.md` frontmatter).
    public static func parseBoardConfig(yaml: String) throws -> BoardConfig {
        let map = try dictionary(from: yaml)
        return BoardConfig(
            lanes: lanes(from: map["lanes"]),
            users: users(from: map["users"]),
            epics: epics(from: map["epics"]),
            priorities: priorities(from: map["priorities"]),
            types: strings(from: map["types"]),
            tags: strings(from: map["tags"]),
            fieldSource: fieldSource(from: map["fieldSource"]),
            reviewPath: map["review_path"] as? String
        )
    }

    /// Parse a `ProjectConfig` from a YAML string (a `Tasks/<project>/README.md` frontmatter).
    public static func parseProjectConfig(yaml: String) throws -> ProjectConfig {
        let map = try dictionary(from: yaml)
        let laneList = map["lanes"].map { lanes(from: $0) }
        return ProjectConfig(
            project: map["project"] as? String,
            lanes: laneList,
            users: map["users"].map { users(from: $0) },
            epics: map["epics"].map { epics(from: $0) },
            priorities: map["priorities"].map { priorities(from: $0) },
            types: map["types"].map { strings(from: $0) },
            tags: map["tags"].map { strings(from: $0) },
            fieldSource: fieldSource(from: map["fieldSource"]),
            reviewPath: map["review_path"] as? String,
            icon: (map["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            color: (map["color"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Config rendering (project README)

    /// Render a full project `README.md`: a YAML frontmatter block (between `---`
    /// fences) followed by `# <name>` and the description. The frontmatter always
    /// carries `config: project` and `project:`, plus `lanes:`, `priorities:` and
    /// `users:` arrays for whichever collections are non-empty. The output is
    /// designed to parse back through `parseProjectConfig(yaml:)` unchanged.
    public static func renderProjectReadme(
        name: String,
        description: String,
        lanes: [Lane],
        priorities: [Priority],
        users: [User],
        types: [String] = [],
        epics: [Epic] = []
    ) -> String {
        var lines: [String] = [
            "---",
            "config: project",
            "project: \(yamlScalar(name))",
        ]

        if !lanes.isEmpty {
            lines.append("lanes:")
            for lane in lanes {
                lines.append("  - id: \(yamlScalar(lane.id))")
                lines.append("    name: \(yamlScalar(lane.name))")
                lines.append("    folder: \(yamlScalar(lane.folder))")
                lines.append("    status: \(yamlScalar(lane.status))")
                if lane.terminal == true {
                    lines.append("    terminal: true")
                }
                if lane.backlog == true {
                    lines.append("    backlog: true")
                }
            }
        }

        if !priorities.isEmpty {
            lines.append("priorities:")
            for priority in priorities {
                lines.append("  - id: \(yamlScalar(priority.id))")
                if let name = priority.name { lines.append("    name: \(yamlScalar(name))") }
                if let description = priority.description { lines.append("    description: \(yamlScalar(description))") }
            }
        }

        if !users.isEmpty {
            lines.append("users:")
            for user in users {
                lines.append("  - id: \(yamlScalar(user.id))")
                if let name = user.name { lines.append("    name: \(yamlScalar(name))") }
                if let kind = user.kind { lines.append("    kind: \(yamlScalar(kind))") }
                if let github = user.github { lines.append("    github: \(yamlScalar(github))") }
                if let role = user.role { lines.append("    role: \(yamlScalar(role))") }
            }
        }

        if !types.isEmpty {
            lines.append("types: [\(types.map { yamlScalar($0) }.joined(separator: ", "))]")
        }

        if !epics.isEmpty {
            lines.append("epics:")
            for epic in epics {
                lines.append("  - id: \(yamlScalar(epic.id))")
                if let name = epic.name { lines.append("    name: \(yamlScalar(name))") }
                if let description = epic.description { lines.append("    description: \(yamlScalar(description))") }
                if let project = epic.project { lines.append("    project: \(yamlScalar(project))") }
            }
        }

        lines.append("---")
        let frontmatter = lines.joined(separator: "\n")
        return "\(frontmatter)\n\n# \(name)\n\n\(description)\n"
    }

    /// Render a YAML scalar, quoting when the value could be misparsed: empty
    /// strings, or any value containing spaces, colons, dots or `#`, or one that
    /// begins with a digit. Backslashes and quotes are escaped inside the quotes.
    public static func yamlScalar(_ value: String) -> String {
        let needsQuote = value.isEmpty
            || value.contains(where: { $0 == " " || $0 == ":" || $0 == "." || $0 == "#" || $0 == "\"" || $0 == "'" })
            || (value.first?.isNumber ?? false)
        guard needsQuote else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: Card parsing

    /// Parse a single card's text into a display `Card`, honouring the field source.
    /// `fileName` supplies id/priority for body-section boards (audit filenames).
    public static func parseCard(text: String, fileName: String? = nil, fieldSource: FieldSource?) -> Card {
        let (frontmatter, body) = BoardMarkdown.splitFrontmatter(text)
        let fields: CardFields
        switch fieldSource {
        case let .bodySection(section, labelMap):
            fields = bodySectionFields(body: body, section: section, map: labelMap, fileName: fileName)
        default:
            fields = frontmatterFields(frontmatter, fileName: fileName)
        }
        var titled = fields
        if titled.title.trimmingCharacters(in: .whitespaces).isEmpty {
            // No usable title field: the card's heading, else its file name. Never blank.
            titled.title = headingTitle(body)
                ?? fileName.map { ($0 as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ") }
                ?? ""
        }
        return Card(fields: titled, body: body, fileName: fileName)
    }

    /// Top-level `key: value` lines read one by one, for frontmatter that is not valid
    /// YAML. One unquoted colon in a value (`title: Check: a follow-up`) makes the whole
    /// block unparseable, and a card must not lose its title, id and status over that.
    public static func lenientFields(_ yaml: String) -> [String: Any] {
        var map: [String: Any] = [:]
        for line in yaml.components(separatedBy: "\n") {
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" "), map[key] == nil else { continue }
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            // Lists, nested maps and block scalars are not plain strings: leave them out.
            if value.isEmpty || value == "null" || value == "~" || value.hasPrefix("[") || value.hasPrefix("{")
                || value == "|" || value == ">" { continue }
            map[key] = value
        }
        return map
    }

    /// The first `# Heading` of a card body, as a title for a card that has none.
    static func headingTitle(_ body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return nil
    }

    private static func frontmatterFields(_ yaml: String?, fileName: String?) -> CardFields {
        let map: [String: Any]
        if let yaml {
            if let parsed = try? dictionary(from: yaml) { map = parsed } else { map = lenientFields(yaml) }
        } else {
            map = [:]
        }
        func str(_ key: String) -> String? {
            // A YAML null (empty `key:`) parses to NSNull — treat it as absent rather
            // than stringifying it to "<null>".
            guard let value = map[key], !(value is NSNull) else { return nil }
            if let string = value as? String { return string }
            // YAML timestamps (`updated_at: 2026-11-08T10:00:00Z`) load as Date.
            if let date = value as? Date { return Review.timestamp(date) }
            return String(describing: value)
        }
        var fields = CardFields(
            id: str("id") ?? "",
            title: str("title") ?? "",
            project: str("project") ?? "",
            status: str("status") ?? "",
            priority: nonEmpty(str("priority")),
            type: nonEmpty(str("type")),
            epic: nonEmpty(str("epic")),
            assignee: nonEmpty(str("assignee")),
            order: nonEmpty(str("order")),
            updatedAt: nonEmpty(str("updated_at")),
            readAt: nonEmpty(str("read_at")),
            readBy: nonEmpty(str("read_by")),
            product: nonEmpty(str("product"))
        )
        // Labels: a list (`tags: [ios, bug]` or one per line), or a single value.
        if let list = map["tags"] as? [Any] {
            fields.tags = list.compactMap { $0 is NSNull ? nil : String(describing: $0) }.filter { !$0.isEmpty }
        } else if let one = nonEmpty(str("tags")) {
            fields.tags = one.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        // A due date is a day: `due: 2026-11-24` (YAML may hand it over as a full timestamp).
        fields.due = nonEmpty(str("due")).map { String($0.prefix(10)) }
        fields.createdAt = nonEmpty(str("created_at"))
        return fields
    }

    private static func bodySectionFields(body: String, section: String?, map: [String: String], fileName: String?) -> CardFields {
        let sectionText = section.map { BoardMarkdown.extractSection(body, $0) } ?? ""
        func value(_ field: String) -> String? {
            guard let label = map[field] else { return nil }
            return BoardMarkdown.extractLabeledValue(sectionText, label)
                ?? BoardMarkdown.extractLabeledValue(body, label)
        }
        let parsedName = fileName.flatMap { BoardMarkdown.parseAuditFilename($0) }
        return CardFields(
            id: value("id") ?? parsedName?.id ?? "",
            title: value("title") ?? BoardMarkdown.extractTitle(body),
            project: value("project") ?? "",
            status: value("status") ?? "",
            priority: value("priority") ?? parsedName?.priority,
            type: value("type"),
            epic: value("epic"),
            assignee: value("assignee"),
            order: nil
        )
    }

    // MARK: Loading + grouping

    /// Load every card file in a folder (skipping README/index files).
    public static func loadCards(in folder: URL, fieldSource: FieldSource?) throws -> [Card] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return try names
            .filter { $0.hasSuffix(".md") && $0 != "README.md" && !$0.hasPrefix("00-") }
            .sorted()
            .map { name in
                let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                return parseCard(text: text, fileName: name, fieldSource: fieldSource)
            }
    }

    /// Group cards into columns in lane order; cards whose status matches no lane
    /// are returned in `uncategorised` rather than dropped.
    public static func columns(cards: [Card], config: EffectiveConfig) -> (columns: [Column], uncategorised: [Card]) {
        var buckets: [String: [Card]] = [:]
        var uncategorised: [Card] = []
        let laneStatuses = Set(config.lanes.map(\.status))
        for card in cards {
            if laneStatuses.contains(card.fields.status) {
                buckets[card.fields.status, default: []].append(card)
            } else {
                uncategorised.append(card)
            }
        }
        let columns = config.lanes.map { lane in
            Column(lane: lane, cards: (buckets[lane.status] ?? []).sorted { lhs, rhs in
                compare(lhs, rhs, config: config) < 0
            })
        }
        return (columns, uncategorised)
    }

    /// Sort a single lane's cards into display order (order → priority → id). Shared
    /// by the disk and remote loaders so a lane looks identical on every platform.
    public static func sortedCards(_ cards: [Card], config: EffectiveConfig) -> [Card] {
        cards.sorted { compare($0, $1, config: config) < 0 }
    }

    private static func compare(_ a: Card, _ b: Card, config: EffectiveConfig) -> Int {
        if let oa = a.fields.order, let ob = b.fields.order, oa != ob {
            // Numbers, not text: a task dropped between 1 and 2 gets 1.5.
            if let ia = Double(oa), let ib = Double(ob), ia != ib { return ia < ib ? -1 : 1 }
            if Double(oa) == nil || Double(ob) == nil { return oa < ob ? -1 : 1 }
        }
        let pa = priorityRank(a.fields.priority, config)
        let pb = priorityRank(b.fields.priority, config)
        if pa != pb { return pa - pb }
        return a.fields.id < b.fields.id ? -1 : (a.fields.id > b.fields.id ? 1 : 0)
    }

    private static func priorityRank(_ priority: String?, _ config: EffectiveConfig) -> Int {
        guard let priority else { return config.priorities.count }
        let index = config.priorities.firstIndex { $0.id == priority }
        return index ?? config.priorities.count
    }

    // MARK: Products

    /// The products a board's README lists (`products:`), in order.
    public static func products(inReadme text: String) -> [BoardProduct] {
        guard let frontmatter = BoardMarkdown.splitFrontmatter(text).frontmatter,
              let map = try? dictionary(from: frontmatter), let list = map["products"] as? [Any] else { return [] }
        var seen = Set<String>()
        return list.compactMap { entry -> BoardProduct? in
            let product: BoardProduct
            if let name = entry as? String {
                product = BoardProduct(id: BoardProduct.id(for: name), name: name)
            } else if let fields = entry as? [String: Any] {
                func text(_ key: String) -> String? { (fields[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
                guard let name = text("name") ?? text("id") else { return nil }
                product = BoardProduct(id: text("id") ?? BoardProduct.id(for: name), name: name,
                                       prefix: BoardProduct.cleanPrefix(text("prefix")), icon: text("icon"), color: text("color"))
            } else { return nil }
            return !product.id.isEmpty && seen.insert(product.id).inserted ? product : nil
        }
    }

    /// The `products:` lines of a README, as a frontmatter of their own (for patching one in).
    public static func renderProducts(_ products: [BoardProduct]) -> String {
        var lines = ["---"]
        if !products.isEmpty {
            lines.append("products:")
            for product in products {
                lines.append("  - id: \(yamlScalar(product.id))")
                lines.append("    name: \(yamlScalar(product.name))")
                if let prefix = product.prefix { lines.append("    prefix: \(yamlScalar(prefix))") }
                if let icon = product.icon { lines.append("    icon: \(yamlScalar(icon))") }
                if let color = product.color { lines.append("    color: \(yamlScalar(color))") }
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: YAML helpers

    private static func dictionary(from yaml: String) throws -> [String: Any] {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        return (try Yams.load(yaml: yaml)) as? [String: Any] ?? [:]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "null" else { return nil }
        return value
    }

    private static func lanes(from value: Any?) -> [Lane] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let status = item["status"] as? String else { return nil }
            return Lane(
                id: id,
                name: item["name"] as? String ?? id,
                folder: item["folder"] as? String ?? "",
                status: status,
                terminal: item["terminal"] as? Bool,
                backlog: item["backlog"] as? Bool
            )
        }
    }

    private static func users(from value: Any?) -> [User] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return User(
                id: id,
                name: item["name"] as? String,
                kind: item["kind"] as? String,
                github: item["github"] as? String,
                role: item["role"] as? String
            )
        }
    }

    private static func epics(from value: Any?) -> [Epic] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return Epic(id: id, name: item["name"] as? String, description: item["description"] as? String, project: item["project"] as? String)
        }
    }

    private static func priorities(from value: Any?) -> [Priority] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return Priority(id: id, name: item["name"] as? String, description: item["description"] as? String)
        }
    }

    private static func strings(from value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }
    }

    private static func fieldSource(from value: Any?) -> FieldSource? {
        guard let map = value as? [String: Any], let mode = map["mode"] as? String else { return nil }
        if mode == "body-section" {
            let labelMap = (map["map"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            return .bodySection(section: map["section"] as? String, map: labelMap)
        }
        return .frontmatter
    }

    // MARK: Workspace loading ([project]/[lane]/[task] hierarchy)

    /// Load the workspace at `root`: the root config plus every project folder
    /// (an immediate subdirectory that contains a `README.md`). Projects are sorted
    /// by display name.
    public static func loadWorkspace(at root: URL) throws -> Workspace {
        let rootConfig = try loadBoardConfig(readme: root.appendingPathComponent("README.md"))

        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var projects: [BoardProject] = []
        for entry in entries {
            let folder = entry.lastPathComponent
            guard !folder.hasPrefix("."), folder != ".git" else { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            let readme = entry.appendingPathComponent("README.md")
            guard fm.fileExists(atPath: readme.path) else { continue }

            let config = try loadProjectConfig(readme: readme)
            let name = config.project?.isEmpty == false ? config.project! : folder
            projects.append(BoardProject(id: folder, name: name, folder: folder, config: config))
        }

        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Workspace(rootConfig: rootConfig, projects: projects)
    }

    /// Resolve and load a single project's board. Cards are read from each lane's
    /// folder (the lane is known from the folder, not the card `status`), and sorted
    /// within a lane the same way `columns(cards:config:)` does. Non-lane subfolders
    /// are ignored; their cards are collected into `uncategorised`.
    public static func loadProjectBoard(
        root: URL,
        project: BoardProject,
        rootConfig: BoardConfig
    ) throws -> LoadedBoard {
        let effective = resolveEffectiveConfig(rootConfig, project.config)
        let projectURL = root.appendingPathComponent(project.folder)

        var columns: [Column] = []
        var laneFolders = Set<String>()
        for lane in effective.lanes {
            laneFolders.insert(lane.folder)
            let laneURL = projectURL.appendingPathComponent(lane.folder)
            let cards: [Card]
            if FileManager.default.fileExists(atPath: laneURL.path) {
                cards = try loadCards(in: laneURL, fieldSource: effective.fieldSource)
            } else {
                cards = []
            }
            let sorted = cards.sorted { compare($0, $1, config: effective) < 0 }
            columns.append(Column(lane: lane, cards: sorted))
        }

        // Cards living in project subfolders that are not lane folders → uncategorised.
        var uncategorised: [Card] = []
        let fm = FileManager.default
        let subEntries = (try? fm.contentsOfDirectory(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in subEntries {
            let folder = entry.lastPathComponent
            guard !folder.hasPrefix("."), !laneFolders.contains(folder) else { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            uncategorised.append(contentsOf: try loadCards(in: entry, fieldSource: effective.fieldSource))
        }

        return LoadedBoard(config: effective, columns: columns, uncategorised: uncategorised)
    }

    /// Parse a `BoardConfig` from a README's frontmatter, defaulting to empty when
    /// the file or its frontmatter is missing.
    private static func loadBoardConfig(readme: URL) throws -> BoardConfig {
        guard let text = try? String(contentsOf: readme, encoding: .utf8) else { return BoardConfig() }
        let (frontmatter, _) = BoardMarkdown.splitFrontmatter(text)
        guard let frontmatter else { return BoardConfig() }
        return try parseBoardConfig(yaml: frontmatter)
    }

    /// Parse a `ProjectConfig` from a README's frontmatter, defaulting to empty when
    /// the frontmatter is missing.
    private static func loadProjectConfig(readme: URL) throws -> ProjectConfig {
        guard let text = try? String(contentsOf: readme, encoding: .utf8) else { return ProjectConfig() }
        let (frontmatter, _) = BoardMarkdown.splitFrontmatter(text)
        guard let frontmatter else { return ProjectConfig() }
        return try parseProjectConfig(yaml: frontmatter)
    }
}

// MARK: Workspace models

/// A project discovered in a workspace: a folder under the root containing a
/// `README.md` project config.
public struct BoardProject: Identifiable, Sendable, Equatable {
    /// Folder name (also the stable identity within a workspace).
    public var id: String
    /// Display name: the project config's `project` name if present, else the folder.
    public var name: String
    /// Folder name under the workspace root.
    public var folder: String
    public var config: ProjectConfig

    public init(id: String, name: String, folder: String, config: ProjectConfig) {
        self.id = id
        self.name = name
        self.folder = folder
        self.config = config
    }
}

/// A loaded workspace: the root board config and the projects it contains.
public struct Workspace: Sendable {
    public var rootConfig: BoardConfig
    public var projects: [BoardProject]

    public init(rootConfig: BoardConfig, projects: [BoardProject]) {
        self.rootConfig = rootConfig
        self.projects = projects
    }
}

/// A single project's resolved board: its effective config plus the laid-out columns.
public struct LoadedBoard: Sendable {
    public var config: EffectiveConfig
    public var columns: [Column]
    public var uncategorised: [Card]

    public init(config: EffectiveConfig, columns: [Column], uncategorised: [Card]) {
        self.config = config
        self.columns = columns
        self.uncategorised = uncategorised
    }
}
