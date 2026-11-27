import Foundation

/// The one manual an agent reads before working on the boards: `tasks guide` prints it and the
/// agent server's `get_agent_guide` tool returns it. The prose is `AgentGuide.md` (embedded in
/// the binary); the command, tool, exit code and environment references are generated here from
/// `CommandTable` and `AgentTools.all`, the same definitions the CLI and the server run on.
public enum AgentGuide {
    /// A board's rule files, as `get_board_rules` returns them: file key → text.
    public struct BoardRules: Sendable, Equatable {
        public let board: String
        public let files: [String: String]

        public init(board: String, files: [String: String]) {
            self.board = board
            self.files = files
        }

        public init(board: String, files: [String: Any]) {
            self.init(board: board, files: files.compactMapValues { $0 as? String })
        }
    }

    /// The prose, with `{{…}}` where the generated references go.
    public static var prose: String { String(decoding: PackageResources.AgentGuide_md, as: UTF8.self) }

    /// The whole guide; with `rules`, that board's rules are appended.
    public static func text(rules: BoardRules? = nil) -> String {
        var text = prose
            .replacingOccurrences(of: "{{commands}}", with: commandReference())
            .replacingOccurrences(of: "{{tools}}", with: toolReference())
            .replacingOccurrences(of: "{{exit-codes}}", with: exitCodeReference())
            .replacingOccurrences(of: "{{environment}}", with: environmentReference())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rules { text += "\n\n" + rulesSection(rules) }
        return text + "\n"
    }

    // MARK: Generated references

    static func commandReference() -> String {
        var out = "Options every command takes:\n\n" + CommandTable.global.map { "- `\($0.label)`: \($0.help)" }.joined(separator: "\n")
        for spec in CommandTable.all {
            out += "\n\n### `tasks \(spec.name)`\n\n\(spec.summary)\n\n"
            out += fence(spec.usage.joined(separator: "\n"))
            if !spec.aliases.isEmpty { out += "\n\nAlso: " + spec.aliases.map { "`\($0)`" }.joined(separator: ", ") + "." }
            if !spec.options.isEmpty {
                out += "\n\n" + spec.options.map { "- `\($0.label)`: \($0.help)" }.joined(separator: "\n")
            }
            if let notes = spec.notes { out += "\n\n" + notes }
            if !spec.examples.isEmpty { out += "\n\nExamples:\n\n" + fence(spec.examples.joined(separator: "\n"), info: "sh") }
            if let returns = spec.returns { out += "\n\n`--json` prints: " + returns }
            let tools = spec.tools.filter { name in AgentTools.all.contains { $0.name == name } }
            if !tools.isEmpty { out += "\n\nTools: " + tools.map { "`\($0)`" }.joined(separator: ", ") + "." }
        }
        return out
    }

    static func toolReference() -> String {
        AgentTools.all.map { tool -> String in
            var out = "### `\(tool.name)`\n\n\(tool.description)"
            let commands = CommandTable.all.filter { $0.tools.contains(tool.name) }.map { "`tasks \($0.name)`" }
            out += "\n\nFrom the command line: " + (commands.isEmpty ? "" : commands.joined(separator: ", ") + ", or ")
                + "`tasks raw \(tool.name) '<json>'`."
            let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) as? [String: Any] ?? [:]
            let arguments = describe(schema, depth: 0)
            out += "\n\n" + (arguments.isEmpty ? "No arguments." : "Arguments (* required):\n\n" + arguments)
            return out
        }.joined(separator: "\n\n")
    }

    /// An object schema's properties as nested bullets: required ones first, then by name.
    private static func describe(_ schema: [String: Any], depth: Int) -> String {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = schema["required"] as? [String] ?? []
        let names = required.filter { properties[$0] != nil } + properties.keys.filter { !required.contains($0) }.sorted()
        let indent = String(repeating: "  ", count: depth)
        return names.map { name -> String in
            let property = properties[name] as? [String: Any] ?? [:]
            var type = property["type"] as? String ?? "any"
            if let values = property["enum"] as? [String] { type = values.joined(separator: " | ") }
            let items = property["items"] as? [String: Any]
            if type == "array", let itemType = items?["type"] as? String { type = "array of \(itemType)s" }
            var line = "\(indent)- `\(name)`\(required.contains(name) ? "*" : "") (\(type))"
            if let description = property["description"] as? String { line += ": \(description)" }
            if let items, items["properties"] != nil {
                line += "\n" + describe(items, depth: depth + 1)
            }
            return line
        }.joined(separator: "\n")
    }

    static func exitCodeReference() -> String {
        "| Code | `kind` | Means | What to do |\n|---|---|---|---|\n"
            + ExitStatus.allCases.map { "| \($0.rawValue) | \($0 == .done ? "" : "`\($0.kind)`") | \($0.meaning) | \($0.whatToDo) |" }.joined(separator: "\n")
    }

    static func environmentReference() -> String {
        CommandTable.environment.map { "- `\($0.name)`: \($0.help)" }.joined(separator: "\n")
    }

    // MARK: A board's rules

    /// The board's rule files, most general first, each in a fence so its own headings and
    /// frontmatter stay as they are.
    public static func rulesSection(_ rules: BoardRules) -> String {
        let files = rules.files
        let order = ["contract", "template"].filter { files[$0] != nil }
            + files.keys.filter { $0.hasPrefix("repository_") }.sorted()
            + ["board_readme"].filter { files[$0] != nil }
            + files.keys.filter { $0.hasPrefix("board_") && $0 != "board_readme" }.sorted()
        let rest = files.keys.filter { !order.contains($0) && $0 != "precedence" }.sorted()
        var out = "## This board's rules: `\(rules.board)`\n\n"
        out += "Fetched from the Tasks app (`get_board_rules`) when this guide was printed. They are this board's contract: "
        out += "where they differ from anything above, they win."
        if let precedence = files["precedence"] { out += " " + precedence }
        for key in order + rest {
            out += "\n\n### \(label(key))\n\n" + fence(files[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines), info: "markdown")
        }
        return out
    }

    static func label(_ key: String) -> String {
        switch key {
        case "contract": return "The repository's contract (its README.md)"
        case "template": return "The card template (TASK_TEMPLATE.md)"
        case "board_readme": return "The board's README.md"
        default:
            if key.hasPrefix("repository_") { return "The repository's \(key.dropFirst("repository_".count))" }
            if key.hasPrefix("board_") { return "The board's \(key.dropFirst("board_".count))" }
            return key
        }
    }

    /// A code fence longer than any run of backticks inside `text`.
    static func fence(_ text: String, info: String = "") -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let marks = String(repeating: "`", count: max(3, longest + 1))
        return "\(marks)\(info)\n\(text)\n\(marks)"
    }
}
