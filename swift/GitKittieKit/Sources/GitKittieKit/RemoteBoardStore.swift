import Foundation

/// An async, transport-agnostic source of repository files. It lets board loading
/// work without a local checkout — iOS feeds it a GitHub-API-backed source (git-pont),
/// macOS could feed it a disk-backed one — so the same board logic runs everywhere.
///
/// Paths are repo-relative and use forward slashes; the repo root is `""`.
public protocol BoardFileSource: Sendable {
    /// The immediate entries under a repo-relative directory (`""` = repo root).
    func list(_ directory: String) async throws -> [BoardFileEntry]
    /// A repo-relative file decoded as UTF-8 text.
    func readText(_ path: String) async throws -> String
}

/// A source that can hand over every text file of a folder in one round trip. Over a
/// provider API a card is otherwise one request each, and a lane can hold hundreds.
public protocol BulkTextSource: BoardFileSource {
    /// File name → text for the text files directly in `directory`, or `nil` when this
    /// source cannot do it in one go here. Files missing from the result are read singly.
    func readTexts(in directory: String) async -> [String: String]?
}

/// One entry in a `BoardFileSource` directory listing.
public struct BoardFileEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case file, directory }
    public let name: String
    public let path: String
    public let kind: Kind

    public init(name: String, path: String, kind: Kind) {
        self.name = name
        self.path = path
        self.kind = kind
    }
}

/// Loads a workspace and project boards through a `BoardFileSource`, mirroring
/// `BoardStore`'s on-disk loaders (`loadWorkspace` / `loadProjectBoard`) but over any
/// async transport. Card parsing, config inheritance and lane sorting are the exact
/// shared `BoardStore` logic, so a board renders identically to the macOS app.
public enum RemoteBoardStore {

    /// Load the workspace. Handles flexible layouts:
    /// - **Direct board:** lanes at the repo root (root README has `lanes`) → one project.
    /// - **Multi-project:** top-level folders that each contain a `README.md`.
    /// - **Nested:** projects under organisational folders at any depth (e.g.
    ///   `project-assets/Tasks/<project>`), found by recursing into folders that only
    ///   contain other project/container folders (not lane folders).
    public static func loadWorkspace(source: BoardFileSource) async throws -> Workspace {
        let rootConfig = (try? await loadBoardConfig(source: source, dir: "")) ?? BoardConfig()
        let rootEntries = (try? await source.list("")) ?? []
        let rootLaneFolders = Set(rootConfig.lanes.map(\.folder))

        // Direct board: the repo root itself holds the lane folders (not sub-projects).
        if !rootConfig.lanes.isEmpty,
           rootEntries.contains(where: { $0.kind == .directory && rootLaneFolders.contains($0.name) }) {
            let project = BoardProject(id: "", name: "Board", folder: "", config: ProjectConfig())
            return Workspace(rootConfig: rootConfig, projects: [project])
        }

        var projects = await discoverProjects(source: source, dir: "", inheritedLanes: rootConfig.lanes, depth: 0)
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Workspace(rootConfig: rootConfig, projects: projects)
    }

    /// Recursively find project folders. A directory is a **project** when its README
    /// carries a project marker (`project:`), or it actually contains the lane folders
    /// of the effective config. Other folders (organisational, e.g. `project-assets/`
    /// or a `Tasks/` root holding per-project folders) are recursed into so boards at
    /// any depth are found — without misreading a lane folder as a project.
    private static func discoverProjects(
        source: BoardFileSource, dir: String, inheritedLanes: [Lane], depth: Int
    ) async -> [BoardProject] {
        guard depth <= 4 else { return [] }
        let entries = (try? await source.list(dir)) ?? []
        let inheritedFolders = Set(inheritedLanes.map(\.folder))
        var found: [BoardProject] = []

        for entry in entries where entry.kind == .directory {
            let name = entry.name
            guard !name.hasPrefix("."), name != "node_modules" else { continue }
            if inheritedFolders.contains(name) { continue }  // a lane folder of this board

            let projectConfig = (try? await loadProjectConfig(source: source, dir: entry.path)) ?? ProjectConfig()
            let ownBoard = (try? await loadBoardConfig(source: source, dir: entry.path)) ?? BoardConfig()
            let lanes = ownBoard.lanes.isEmpty ? inheritedLanes : ownBoard.lanes
            let laneFolders = Set(lanes.map(\.folder))
            let children = (try? await source.list(entry.path)) ?? []
            let hasLaneFolders = children.contains { $0.kind == .directory && laneFolders.contains($0.name) }

            if projectConfig.project != nil || hasLaneFolders {
                let display = projectConfig.project?.isEmpty == false ? projectConfig.project! : name
                found.append(BoardProject(id: entry.path, name: display, folder: entry.path, config: projectConfig))
            } else {
                found += await discoverProjects(source: source, dir: entry.path, inheritedLanes: lanes, depth: depth + 1)
            }
        }
        return found
    }

    /// Resolve and load one project's board. Cards are read from each lane's folder
    /// (the lane is known from the folder, not the card `status`) and sorted the same
    /// way the disk loader sorts them. Non-lane subfolders become `uncategorised`.
    public static func loadProjectBoard(
        source: BoardFileSource,
        project: BoardProject,
        rootConfig: BoardConfig,
        loadBacklog: Bool = true
    ) async throws -> LoadedBoard {
        let effective = resolveEffectiveConfig(rootConfig, project.config)
        let laneFolders = Set(effective.lanes.map(\.folder))

        // Load all lanes concurrently (each lane's cards also load concurrently), so a
        // board over the API isn't gated on sequential per-file round-trips. Backlog
        // lanes are skipped unless requested — they can be large and load on demand.
        let columns = try await withThrowingTaskGroup(of: (Int, Column).self) { group -> [Column] in
            for (index, lane) in effective.lanes.enumerated() {
                group.addTask {
                    guard loadBacklog || !lane.isBacklog else {
                        return (index, Column(lane: lane, cards: []))
                    }
                    let cards = try await loadCards(
                        source: source,
                        dir: join(project.folder, lane.folder),
                        fieldSource: effective.fieldSource
                    )
                    return (index, Column(lane: lane, cards: BoardStore.sortedCards(cards, config: effective)))
                }
            }
            var results: [(Int, Column)] = []
            for try await pair in group { results.append(pair) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var uncategorised: [Card] = []
        let subEntries = (try? await source.list(project.folder)) ?? []
        for entry in subEntries where entry.kind == .directory {
            guard !entry.name.hasPrefix("."), !laneFolders.contains(entry.name), entry.name != "attachments", entry.name != "docs", entry.name != Review.defaultReviewPath else { continue }
            uncategorised += try await loadCards(source: source, dir: entry.path, fieldSource: effective.fieldSource)
        }

        return LoadedBoard(config: effective, columns: columns, uncategorised: uncategorised)
    }

    /// Open a specific board by its project folder (`""` = the repo root board), without
    /// a full workspace scan. Returns the project, the root config it inherits from, and
    /// the loaded board. `folder` is relative to the source root.
    public static func loadBoard(
        source: BoardFileSource, folder: String, loadBacklog: Bool = false
    ) async throws -> (project: BoardProject, rootConfig: BoardConfig, board: LoadedBoard) {
        // The root board config lives in the project's parent directory (e.g.
        // `Tasks/README.md` for a `Tasks/<project>` board), so a project that leaves
        // `lanes: []` inherits the parent board's lanes. Fall back to the repo root.
        let rootConfig = await resolveRootConfig(source: source, projectFolder: folder)
        let projectConfig = (try? await loadProjectConfig(source: source, dir: folder)) ?? ProjectConfig()
        let fallback = folder.split(separator: "/").last.map(String.init) ?? "Board"
        let name = projectConfig.project?.isEmpty == false ? projectConfig.project! : fallback
        let project = BoardProject(id: folder, name: name, folder: folder, config: projectConfig)
        let board = try await loadProjectBoard(source: source, project: project, rootConfig: rootConfig, loadBacklog: loadBacklog)
        return (project, rootConfig, board)
    }

    /// Load the cards in a directory (no config needed) — used to auto-detect a board's
    /// structure from its folders and card fields.
    public static func cards(source: BoardFileSource, dir: String) async throws -> [Card] {
        try await loadCards(source: source, dir: dir, fieldSource: nil)
    }

    /// Count the cards in a board without reading their contents — just list each lane
    /// folder and count card files. Used for the boards list's "N tasks" summary.
    public static func taskCount(source: BoardFileSource, folder: String) async throws -> Int {
        try await listing(source: source, folder: folder).total
    }

    /// Which card files sit in which lane, from directory listings alone (no card file is
    /// read). Cheap enough to run for every board on the home screen.
    public static func listing(source: BoardFileSource, folder: String) async throws -> BoardListing {
        let rootConfig = await resolveRootConfig(source: source, projectFolder: folder)
        // nil when the README could not be read (offline, rate-limited, a slow host): then
        // the listing does not know the board's name, icon or colour, and says so.
        let readConfig: ProjectConfig? = await {
            guard let text = try? await source.readText(join(folder, "README.md")) else { return nil }
            let (frontmatter, _) = BoardMarkdown.splitFrontmatter(text)
            guard let frontmatter else { return ProjectConfig() }
            return try? BoardStore.parseProjectConfig(yaml: frontmatter)
        }()
        let projectConfig = readConfig ?? ProjectConfig()
        let lanes = resolveEffectiveConfig(rootConfig, projectConfig).lanes.filter { !$0.folder.isEmpty }
        var result = try await listing(source: source, folder: folder, lanes: lanes)
        result.readAppearance = readConfig != nil
        result.name = projectConfig.project.flatMap { $0.isEmpty ? nil : $0 }
        result.icon = projectConfig.icon
        result.color = projectConfig.color
        return result
    }

    /// A board's effective config (its own README over the root it inherits from) and
    /// name, read from the two READMEs alone.
    public static func loadEffectiveConfig(source: BoardFileSource, folder: String) async -> (name: String, config: EffectiveConfig) {
        let rootConfig = await resolveRootConfig(source: source, projectFolder: folder)
        let projectConfig = (try? await loadProjectConfig(source: source, dir: folder)) ?? ProjectConfig()
        let fallback = folder.split(separator: "/").last.map(String.init) ?? "Board"
        let name = projectConfig.project?.isEmpty == false ? projectConfig.project! : fallback
        return (name, resolveEffectiveConfig(rootConfig, projectConfig))
    }

    /// A board without its cards: the project, its config and lanes, and which card files
    /// exist. Enough to file a new card (lanes, a free file name) at a fraction of the
    /// requests a full load costs over a provider API.
    public static func loadBoardShell(
        source: BoardFileSource, folder: String
    ) async throws -> (project: BoardProject, rootConfig: BoardConfig, board: LoadedBoard, listing: BoardListing) {
        let rootConfig = await resolveRootConfig(source: source, projectFolder: folder)
        let projectConfig = (try? await loadProjectConfig(source: source, dir: folder)) ?? ProjectConfig()
        let fallback = folder.split(separator: "/").last.map(String.init) ?? "Board"
        let name = projectConfig.project?.isEmpty == false ? projectConfig.project! : fallback
        let project = BoardProject(id: folder, name: name, folder: folder, config: projectConfig)
        let effective = resolveEffectiveConfig(rootConfig, projectConfig)
        let listing = try await listing(source: source, folder: folder, lanes: effective.lanes.filter { !$0.folder.isEmpty })
        let board = LoadedBoard(config: effective, columns: effective.lanes.map { Column(lane: $0, cards: []) }, uncategorised: [])
        return (project, rootConfig, board, listing)
    }

    private static func listing(source: BoardFileSource, folder: String, lanes: [Lane]) async throws -> BoardListing {
        try await withThrowingTaskGroup(of: (String, [String]).self) { group -> BoardListing in
            for lane in lanes {
                group.addTask {
                    let entries = (try? await source.list(join(folder, lane.folder))) ?? []
                    let files = entries.filter {
                        $0.kind == .file && $0.name.hasSuffix(".md") && $0.name != "README.md" && !$0.name.hasPrefix("00-")
                    }.map(\.name)
                    return (lane.id, files)
                }
            }
            var files: [String: [String]] = [:]
            for try await (lane, names) in group { files[lane] = names }
            return BoardListing(lanes: lanes, files: files)
        }
    }

    /// Load (and sort) the cards for a single lane on demand — used to lazily load a
    /// backlog lane that `loadProjectBoard(loadBacklog: false)` skipped.
    public static func loadLaneCards(
        source: BoardFileSource, project: BoardProject, lane: Lane, rootConfig: BoardConfig
    ) async throws -> [Card] {
        let effective = resolveEffectiveConfig(rootConfig, project.config)
        let cards = try await loadCards(
            source: source, dir: join(project.folder, lane.folder), fieldSource: effective.fieldSource)
        return BoardStore.sortedCards(cards, config: effective)
    }

    // MARK: - Helpers

    /// Load every card file in a directory (skipping README/index files), matching
    /// `BoardStore.loadCards`'s filtering and pre-sort by file name.
    private static func loadCards(
        source: BoardFileSource,
        dir: String,
        fieldSource: FieldSource?
    ) async throws -> [Card] {
        let entries = (try? await source.list(dir)) ?? []
        let names = entries
            .filter { $0.kind == .file }
            .filter { $0.name.hasSuffix(".md") && $0.name != "README.md" && !$0.name.hasPrefix("00-") }
            .sorted { $0.name < $1.name }

        // One round trip for the whole folder where the source can; whatever that leaves
        // out is read file by file, concurrently. File-name order is restored after.
        let bulk = names.isEmpty ? nil : await (source as? any BulkTextSource)?.readTexts(in: dir)
        return try await withThrowingTaskGroup(of: (Int, Card).self) { group -> [Card] in
            for (index, entry) in names.enumerated() {
                group.addTask {
                    let text: String
                    if let known = bulk?[entry.name] { text = known } else { text = try await source.readText(entry.path) }
                    return (index, BoardStore.parseCard(text: text, fileName: entry.name, fieldSource: fieldSource))
                }
            }
            var results: [(Int, Card)] = []
            for try await pair in group { results.append(pair) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// The root board config a project inherits from. Walk up from the project's parent
    /// directory to the repo root, using the first README that declares any lanes; if
    /// none do, fall back to the immediate parent (then repo root). This lets a
    /// `Tasks/<project>` board inherit the lanes defined in `Tasks/README.md`, and a
    /// project at the repo root inherit the root README.
    private static func resolveRootConfig(source: BoardFileSource, projectFolder: String) async -> BoardConfig {
        var dir = parentDir(projectFolder)
        while true {
            if let config = try? await loadBoardConfig(source: source, dir: dir), !config.lanes.isEmpty {
                return config
            }
            if dir.isEmpty { break }
            dir = parentDir(dir)
        }
        // No ancestor defined lanes — use the immediate parent's config (vocab may still
        // be inherited), falling back to the repo root.
        let parent = parentDir(projectFolder)
        if let config = try? await loadBoardConfig(source: source, dir: parent) {
            return config
        }
        if let root = try? await loadBoardConfig(source: source, dir: "") {
            return root
        }
        return BoardConfig()
    }

    /// The parent directory of a repo-relative path ("" for a top-level entry).
    private static func parentDir(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private static func loadBoardConfig(source: BoardFileSource, dir: String) async throws -> BoardConfig {
        guard let text = try? await source.readText(join(dir, "README.md")) else { return BoardConfig() }
        let (frontmatter, _) = BoardMarkdown.splitFrontmatter(text)
        guard let frontmatter else { return BoardConfig() }
        return try BoardStore.parseBoardConfig(yaml: frontmatter)
    }

    private static func loadProjectConfig(source: BoardFileSource, dir: String) async throws -> ProjectConfig {
        guard let text = try? await source.readText(join(dir, "README.md")) else { return ProjectConfig() }
        let (frontmatter, _) = BoardMarkdown.splitFrontmatter(text)
        guard let frontmatter else { return ProjectConfig() }
        return try BoardStore.parseProjectConfig(yaml: frontmatter)
    }

    /// Join two repo-relative path components with a single `/`, tolerating an empty
    /// base (the repo root).
    private static func join(_ base: String, _ component: String) -> String {
        base.isEmpty ? component : "\(base)/\(component)"
    }
}

/// A board's card files per lane, without their contents.
public struct BoardListing: Sendable, Equatable {
    public var lanes: [Lane]
    /// Lane id → card file names.
    public var files: [String: [String]]
    /// The board's `project:` name, `icon:` and `color:`, when the listing was made from its README.
    public var name: String?
    public var icon: String?
    public var color: String?
    /// Whether the README was read, so `name`, `icon` and `color` are what it says. When it
    /// was not, they are unknown, not empty: a saved icon must not be cleared for them.
    public var readAppearance = false

    public init(lanes: [Lane], files: [String: [String]]) {
        self.lanes = lanes
        self.files = files
    }

    public var total: Int { files.values.reduce(0) { $0 + $1.count } }
    public func count(in lane: Lane) -> Int { files[lane.id]?.count ?? 0 }

    /// Card file name → the lane it is in.
    public var locations: [String: String] {
        var result: [String: String] = [:]
        for (lane, names) in files { for name in names { result[name] = lane } }
        return result
    }

    /// How many cards are new or sit in a different lane than in an earlier snapshot.
    public func changes(since snapshot: [String: String]) -> Int {
        locations.reduce(0) { $0 + (snapshot[$1.key] == $1.value ? 0 : 1) }
    }
}
