import Foundation
import GitKittieKit

/// A folder of pages kept somewhere else than the board: in a project's own code
/// repository, next to the code. The board's README names it (`docs:`), and the pages are
/// shown with the board's own without being copied.
public struct DocSource: Identifiable, Equatable, Hashable, Sendable {
    /// `owner/name` (on GitLab the owner may be `group/subgroup`).
    public var repo: String
    /// The folder inside that repository, `""` for its root.
    public var folder: String
    /// A branch other than the repository's default one.
    public var branch: String?
    /// Whether pages may be changed from here. A save is a commit to that repository.
    public var editable: Bool

    public init(repo: String, folder: String, branch: String? = nil, editable: Bool = true) {
        self.repo = repo; self.folder = folder; self.branch = branch; self.editable = editable
    }

    public var id: String { "\(repo):\(folder)" }
    public var name: String { String(repo.split(separator: "/").last ?? "") }
    public var owner: String { repo.split(separator: "/").dropLast().joined(separator: "/") }
    public var label: String { folder.isEmpty ? name : "\(name) · \(folder)" }

    /// `owner/name:folder`, then `@branch` and `readonly` when set: how the README holds it.
    public var written: String {
        var text = id
        if let branch, !branch.isEmpty { text += " @\(branch)" }
        if !editable { text += " readonly" }
        return text
    }

    /// From `owner/name:folder [@branch] [readonly]`; `owner/name/folder` is read too.
    public init?(written raw: String) {
        let words = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).split(separator: " ").map(String.init)
        guard let place = words.first else { return nil }
        let repo: String, folder: String
        if let colon = place.firstIndex(of: ":") {
            repo = String(place[..<colon]); folder = String(place[place.index(after: colon)...])
        } else {
            let parts = place.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            repo = parts.prefix(2).joined(separator: "/"); folder = parts.dropFirst(2).joined(separator: "/")
        }
        let clean = repo.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard clean.split(separator: "/").count >= 2, !folder.contains("..") else { return nil }
        self.init(repo: clean, folder: folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
                  branch: words.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) },
                  editable: !words.contains("readonly"))
    }
}

/// A page of a board's documentation: a Markdown file in the board's `docs` folder, the
/// text of its `README.md` ("About"), or a page of a linked folder in another repository.
public struct BoardDoc: Identifiable, Equatable, Sendable {
    /// Where the page comes from; nil for the board's own pages.
    public var source: DocSource?
    /// Relative to the board (`docs/plan.md`, `README.md`), or to the linked folder
    /// (`systems/camera.md`).
    public var path: String
    public var title: String
    /// The page's Markdown. For the README: its text without the frontmatter. Empty until
    /// `isLoaded`: the pages of a linked folder are listed first and read when opened.
    public var text: String
    public var isLoaded = true

    public var id: String { source.map { "\($0.id)/\(path)" } ?? path }
    public var isAbout: Bool { source == nil && path == BoardDocs.aboutPath }
    public var fileName: String { (path as NSString).lastPathComponent }
    /// The folder the page is in, inside its source: `systems`, or `""`.
    public var group: String {
        let folder = (path as NSString).deletingLastPathComponent
        return source == nil ? "" : folder
    }
    /// Whether it may be changed from here.
    public var isEditable: Bool { source?.editable ?? true }
}

/// One place a search found.
public struct BoardDocHit: Identifiable, Equatable, Sendable {
    public var doc: String
    public var path: String
    public var title: String
    /// The nearest heading above the line, when there is one.
    public var heading: String?
    public var line: String
    public var lineNumber: Int
    public var id: String { "\(doc)#\(lineNumber)" }
}

/// Reading, writing and searching a board's pages. Shared by the apps and the agent tools.
public enum BoardDocs {
    public static let folder = "docs"
    public static let aboutPath = "README.md"
    /// The README key that lists linked folders.
    public static let sourcesKey = "docs"

    static func join(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: "/") }

    /// The first `# heading` of a page, or its file name without the extension.
    public static func title(of text: String, fileName: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return readable(fileName)
    }

    /// `camera-rules.md` → `camera rules`.
    static func readable(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// `Camera rules!` → `camera-rules.md`.
    public static func fileName(for title: String) -> String {
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { text, character in if !(character == "-" && text.hasSuffix("-")) { text.append(character) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (slug.isEmpty ? "page" : String(slug.prefix(60))) + ".md"
    }

    // MARK: Linked folders, in the README

    /// The linked folders a README names: `docs:` as one value or as a list.
    public static func sources(inReadme text: String) -> [DocSource] {
        guard let frontmatter = BoardMarkdown.splitFrontmatter(text).frontmatter else { return [] }
        var found: [DocSource] = []
        var inList = false
        for line in frontmatter.components(separatedBy: "\n") {
            if let first = line.first, !first.isWhitespace, first != "-" {
                inList = false
                guard let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces) == sourcesKey else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.isEmpty { inList = true } else if let source = DocSource(written: value) { found.append(source) }
            } else if inList {
                let item = line.trimmingCharacters(in: .whitespaces)
                guard item.hasPrefix("-") else { continue }
                if let source = DocSource(written: String(item.dropFirst())) { found.append(source) }
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// `text` with its `docs:` list replaced by `sources` (removed when there are none).
    /// Every other line of the README stays as it is.
    public static func setting(_ sources: [DocSource], inReadme text: String) -> String {
        let (frontmatter, body) = BoardMarkdown.splitFrontmatter(text)
        var kept: [String] = []
        var skipping = false
        for line in (frontmatter ?? "").components(separatedBy: "\n") {
            if let first = line.first, !first.isWhitespace, first != "-" {
                skipping = false
                if let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces) == sourcesKey { skipping = true; continue }
            } else if skipping { continue }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { kept.append(line) }
        }
        if !sources.isEmpty {
            kept.append("\(sourcesKey):")
            kept.append(contentsOf: sources.map { "  - \"\($0.written)\"" })
        }
        return "---\n\(kept.joined(separator: "\n"))\n---\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    // MARK: Reading

    /// The board's own pages: the pages in `docs`, A to Z, and before them "About" when
    /// the README says anything.
    public static func load(source: any BoardFileSource, boardFolder: String) async -> [BoardDoc] {
        var pages: [BoardDoc] = []
        if let readme = try? await source.readText(join(boardFolder, aboutPath)) {
            let body = BoardMarkdown.splitFrontmatter(readme).body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { pages.append(BoardDoc(path: aboutPath, title: "About", text: body + "\n")) }
        }
        let directory = join(boardFolder, folder)
        let names = ((try? await source.list(directory)) ?? [])
            .filter { $0.kind == .file && $0.name.lowercased().hasSuffix(".md") }.map(\.name).sorted()
        guard !names.isEmpty else { return pages }
        let bulk = await (source as? any BulkTextSource)?.readTexts(in: directory)
        for name in names {
            let text: String
            if let known = bulk?[name] { text = known }
            else if let read = try? await source.readText(join(directory, name)) { text = read }
            else { continue }
            pages.append(BoardDoc(path: join(folder, name), title: title(of: text, fileName: name), text: text))
        }
        return pages
    }

    /// The pages of a linked folder, with their subfolders, listed but not read yet.
    public static func list(_ linked: DocSource, through source: any BoardFileSource, depth: Int = 4) async -> [BoardDoc] {
        // One request for the whole folder where the source can: a docs folder with
        // hundreds of subfolders is otherwise a request per subfolder.
        if let files = await (source as? any TreeListingSource)?.listFiles(under: linked.folder) {
            let prefix = linked.folder.isEmpty ? "" : linked.folder + "/"
            return files
                .filter { $0.name.lowercased().hasSuffix(".md") && $0.path.hasPrefix(prefix) }
                .map { String($0.path.dropFirst(prefix.count)) }
                .filter { path in !path.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "node_modules" } }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { BoardDoc(source: linked, path: $0, title: readable(($0 as NSString).lastPathComponent), text: "", isLoaded: false) }
        }
        var pages: [BoardDoc] = []
        var folders = [""]
        var level = 0
        while !folders.isEmpty, level <= depth {
            var next: [String] = []
            for sub in folders {
                let entries = (try? await source.list(join(linked.folder, sub))) ?? []
                for entry in entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                    if entry.kind == .directory {
                        if !entry.name.hasPrefix("."), entry.name != "node_modules" { next.append(join(sub, entry.name)) }
                    } else if entry.name.lowercased().hasSuffix(".md") {
                        pages.append(BoardDoc(source: linked, path: join(sub, entry.name), title: readable(entry.name), text: "", isLoaded: false))
                    }
                }
            }
            folders = next
            level += 1
        }
        return pages
    }

    /// One linked page's text.
    public static func read(_ page: BoardDoc, through source: any BoardFileSource) async throws -> BoardDoc {
        guard let linked = page.source else { return page }
        var loaded = page
        loaded.text = try await source.readText(join(linked.folder, page.path))
        loaded.title = title(of: loaded.text, fileName: page.fileName)
        loaded.isLoaded = true
        return loaded
    }

    /// Every page of `pages` that is not read yet, read: a folder at a time where the
    /// source can, so a search over hundreds of pages is a handful of requests.
    public static func readAll(_ pages: [BoardDoc], of linked: DocSource, through source: any BoardFileSource) async -> [BoardDoc] {
        let folders = Array(Set(pages.filter { !$0.isLoaded && $0.source == linked }.map(\.group)))
        guard !folders.isEmpty else { return pages }
        let wanted = Dictionary(grouping: pages.filter { !$0.isLoaded && $0.source == linked }, by: \.group)
        // Eight folders at a time: fast enough for hundreds, gentle enough for the host.
        var read: [String: BoardDoc] = [:]
        var index = 0
        while index < folders.count {
            let batch = folders[index..<min(index + 8, folders.count)]
            index += 8
            await withTaskGroup(of: [BoardDoc].self) { group in
                for sub in batch {
                    let inFolder = wanted[sub] ?? []
                    group.addTask {
                        let bulk = await (source as? any BulkTextSource)?.readTexts(in: join(linked.folder, sub))
                        var done: [BoardDoc] = []
                        for page in inFolder {
                            if let text = bulk?[page.fileName] {
                                var loaded = page
                                loaded.text = text
                                loaded.title = title(of: text, fileName: page.fileName)
                                loaded.isLoaded = true
                                done.append(loaded)
                            } else if let loaded = try? await BoardDocs.read(page, through: source) {
                                done.append(loaded)
                            }
                        }
                        return done
                    }
                }
                for await done in group { for page in done { read[page.id] = page } }
            }
        }
        return pages.map { read[$0.id] ?? $0 }
    }

    /// Lines that contain every word of `query`, with the heading they stand under. A
    /// page whose title matches is listed once more with its first line.
    public static func search(_ pages: [BoardDoc], query: String, limit: Int = 80) -> [BoardDocHit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var hits: [BoardDocHit] = []
        for page in pages {
            var heading: String?
            var found = false
            for (index, raw) in page.text.components(separatedBy: "\n").enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") { heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
                guard !line.isEmpty, words.allSatisfy(line.lowercased().contains) else { continue }
                hits.append(BoardDocHit(doc: page.id, path: page.id, title: page.title, heading: heading == line ? nil : heading, line: line, lineNumber: index + 1))
                found = true
                if hits.count >= limit { return hits }
            }
            if !found, words.allSatisfy(page.title.lowercased().contains) {
                let first = page.text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                hits.append(BoardDocHit(doc: page.id, path: page.id, title: page.title, heading: nil, line: first.trimmingCharacters(in: .whitespaces), lineNumber: 1))
            }
        }
        return hits
    }

    // MARK: Writing

    /// A page of the board itself, as given by a caller, checked: `docs/<name>.md` or `README.md`.
    static func checked(_ raw: String) throws -> String {
        var path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if path.lowercased() == "readme.md" || path.lowercased() == "about" { return aboutPath }
        if !path.hasPrefix(folder + "/") { path = join(folder, path) }
        if !path.lowercased().hasSuffix(".md") { path += ".md" }
        let name = String(path.dropFirst(folder.count + 1))
        guard !name.isEmpty, !name.contains("/"), !name.contains(".."), !name.hasPrefix(".") else {
            throw AgentBoardError("\"\(raw)\" is not a page of this board. Its own pages are files directly in docs/, such as docs/plan.md.")
        }
        return path
    }

    /// Write a page of the board. For the README only the text under the frontmatter is replaced.
    static func write(source: any BoardWritable, boardFolder: String, path: String, text: String, message: String) async throws {
        let full = join(boardFolder, path)
        if path == aboutPath {
            let original = (try? await source.readText(full)) ?? ""
            try await source.write(path: full, text: CardText.update(original, set: [:], body: text), message: message)
        } else {
            try await source.write(path: full, text: text.hasSuffix("\n") ? text : text + "\n", message: message)
        }
    }
}

// MARK: - For agents

extension AgentBoard {
    static func describe(_ page: BoardDoc, withText: Bool) -> [String: Any] {
        var out: [String: Any] = ["path": page.id, "title": page.title, "editable": page.isEditable]
        if let source = page.source { out["from"] = source.repo }
        if withText { out["text"] = page.text; out["characters"] = page.text.count }
        return out
    }

    /// The linked folders this board's README names.
    func docSources() async -> [DocSource] {
        guard let readme = try? await source.readText(BoardDocs.join(folder, BoardDocs.aboutPath)) else { return [] }
        return BoardDocs.sources(inReadme: readme)
    }

    /// Every page: the board's own, then those of each linked folder that can be reached.
    func allDocs(readingLinked: Bool) async -> [BoardDoc] {
        var pages = await BoardDocs.load(source: source, boardFolder: folder)
        for linked in await docSources() {
            guard let through = await linkedSource?(linked) else { continue }
            let listed = await BoardDocs.list(linked, through: through)
            pages += readingLinked ? await BoardDocs.readAll(listed, of: linked, through: through) : listed
        }
        return pages
    }

    func listDocs() async -> [String: Any] {
        ["docs": await allDocs(readingLinked: false).map { Self.describe($0, withText: false) }]
    }

    func page(_ raw: String) async throws -> BoardDoc {
        let wanted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let pages = await allDocs(readingLinked: false)
        if wanted.contains(":") {
            guard let found = pages.first(where: { $0.id.lowercased() == wanted.lowercased() }), let linked = found.source,
                  let through = await linkedSource?(linked) else {
                throw AgentBoardError("No page \"\(raw)\" in this board's linked docs. Use a path as list_docs gives it.")
            }
            return try await BoardDocs.read(found, through: through)
        }
        let path = try BoardDocs.checked(wanted)
        guard let page = pages.first(where: { $0.source == nil && $0.path.lowercased() == path.lowercased() }) else {
            throw AgentBoardError("No page \"\(raw)\" on this board. Its own pages are: \(pages.filter { $0.source == nil }.map(\.path).joined(separator: ", ")).")
        }
        return page
    }

    func getDoc(_ raw: String) async throws -> [String: Any] {
        Self.describe(try await page(raw), withText: true)
    }

    func searchDocs(_ query: String) async -> [String: Any] {
        let pages = await allDocs(readingLinked: true)
        return ["hits": BoardDocs.search(pages, query: query).map { hit -> [String: Any] in
            var out: [String: Any] = ["path": hit.path, "title": hit.title, "line": hit.line, "line_number": hit.lineNumber]
            out["heading"] = hit.heading
            return out
        }]
    }

    /// Create a page, or replace one. Replacing needs `replaces`: the text the caller read,
    /// so a page someone else changed in the meantime is not overwritten.
    func writeDoc(path raw: String?, title: String?, text: String, replaces: String?, agent: String?) async throws -> [String: Any] {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard raw != nil || !cleanTitle.isEmpty else { throw AgentBoardError("Give \"path\" for an existing page, or \"title\" for a new one.") }
        let by = agent.map { " (\($0))" } ?? ""
        if let raw, raw.contains(":") {
            // A page of a linked folder: only an existing one, and only where editing is on.
            let existing = try await page(raw)
            guard let linked = existing.source, linked.editable, let through = await linkedSource?(linked) else {
                throw AgentBoardError("\(existing.id) is read-only here: it lives in \(existing.source?.repo ?? "another repository"). Change it there, or have the owner switch editing on for that folder in Board Settings.")
            }
            try Self.checkUnchanged(existing, replaces)
            try await through.write(path: BoardDocs.join(linked.folder, existing.path), text: text.hasSuffix("\n") ? text : text + "\n", message: "Update \(existing.path)\(by)")
            return ["path": existing.id, "created": false]
        }
        let path = try BoardDocs.checked(raw ?? BoardDocs.fileName(for: cleanTitle))
        let pages = await BoardDocs.load(source: source, boardFolder: folder)
        let existing = pages.first { $0.path.lowercased() == path.lowercased() }
        if let existing { try Self.checkUnchanged(existing, replaces) }
        var body = text
        if existing == nil, !cleanTitle.isEmpty, !body.trimmingCharacters(in: .whitespaces).hasPrefix("# ") { body = "# \(cleanTitle)\n\n\(body)" }
        try await BoardDocs.write(source: source, boardFolder: folder, path: existing?.path ?? path, text: body,
                                  message: "\(existing == nil ? "Add" : "Update") \(existing?.path ?? path)\(by)")
        return ["path": existing?.path ?? path, "created": existing == nil]
    }

    private static func checkUnchanged(_ existing: BoardDoc, _ replaces: String?) throws {
        guard let replaces else {
            throw AgentBoardError("\(existing.id) exists. To change it, read it with get_doc and pass the text you read as \"replaces\".")
        }
        guard replaces.trimmingCharacters(in: .whitespacesAndNewlines) == existing.text.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AgentBoardError("\(existing.id) changed since you read it. Read it again with get_doc and redo your change on the current text.")
        }
    }

    func deleteDoc(_ raw: String) async throws -> [String: Any] {
        guard !raw.contains(":") else { throw AgentBoardError("Pages of a linked folder are deleted in their own repository, not from the board.") }
        let page = try await page(raw)
        guard !page.isAbout else { throw AgentBoardError("The README is the board's configuration and cannot be deleted.") }
        try await source.delete(path: BoardDocs.join(folder, page.path), message: "Delete \(page.path)")
        return ["deleted": page.path]
    }
}
