import Foundation
import GitKittieKit
import GitPontCore
import GitPontGitHub
import GitPontGitLab
import Observation

/// Which hosted provider a connection targets. Self-hosted GitLab carries its own
/// server URL; the others are fixed instances.
public enum ProviderChoice: String, CaseIterable, Identifiable, Codable {
    case github
    case gitlabCloud
    case gitlabSelfHosted
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .github: return "GitHub"
        case .gitlabCloud: return "GitLab.com"
        case .gitlabSelfHosted: return "GitLab (self-hosted)"
        }
    }

    public var needsServerURL: Bool { self == .gitlabSelfHosted }
}

/// How the board is laid out: horizontal kanban lanes or a grouped vertical list.
public enum BoardViewMode: String, CaseIterable, Identifiable {
    case lanes
    case list
    /// A month, with each task on the day it is due.
    case calendar
    public var id: String { rawValue }
}

/// An active provider connection: the git-pont provider + instance + token used for
/// every API call, plus the signed-in account login.
public struct ProviderConnection {
    public let choice: ProviderChoice
    public let instance: GitProviderInstance
    public let provider: any GitProvider
    public let token: String
    public let login: String

    public var requestContext: GitProviderRequestContext {
        let now = Date()
        let connection = GitConnection(
            id: instance.id, instance: instance, accountID: login, accountLogin: login,
            authMethod: .personalAccessToken, createdAt: now, updatedAt: now
        )
        return GitProviderRequestContext(connection: connection, credential: GitCredential(accessToken: token))
    }
}

/// A board as it was last on screen (see `AppModel.boardCache`).
struct CachedBoard {
    var workspace: Workspace
    var project: BoardProject
    var board: LoadedBoard
    var loadedBacklogLanes: Set<String>
    var docs: [BoardDoc]
    var docSources: [DocSource]
    var products: [BoardProduct] = []
}

/// The top-level GitKanban view model, shared by the iOS and macOS apps. Provider-
/// agnostic: connects to GitHub, GitLab.com, or a self-hosted GitLab (personal access
/// token or GitHub OAuth) via git-pont, then loads/edits the board over the provider
/// API — no local clone.
@MainActor
@Observable
public final class AppModel {
    /// Storage private to the running app (macOS, tests).
    public init() {
        defaults = .standard
        keychain = KeychainService(service: Bundle.main.bundleIdentifier ?? "app.hakobs.gitkanban")
        legacyKeychain = nil
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.hakobs.gitkanban", isDirectory: true)
        outbox = Outbox(directory: support.appendingPathComponent("Outbox", isDirectory: true))
        readCache = ReadCache(directory: support.appendingPathComponent("ReadCache", isDirectory: true))
    }

    /// Storage shared through an App Group, so the app and its share extension see the
    /// same boards, connection and token. `migratesLegacyStorage` is for the app itself:
    /// it moves what an earlier version kept in its private defaults and keychain item.
    public init(appGroup: String, keychainService: String, migratesLegacyStorage: Bool) {
        defaults = UserDefaults(suiteName: appGroup) ?? .standard
        keychain = KeychainService(service: keychainService, accessGroup: appGroup)
        legacyKeychain = migratesLegacyStorage
            ? KeychainService(service: Bundle.main.bundleIdentifier ?? keychainService) : nil
        // The outbox lives in the group container so a write saved by the share extension
        // is sent by the app if the extension is closed first. Outside a real App Group
        // (tests) it falls back to a folder named after the suite.
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(appGroup, isDirectory: true)
        outbox = Outbox(directory: container.appendingPathComponent("Outbox", isDirectory: true))
        readCache = ReadCache(directory: container.appendingPathComponent("ReadCache", isDirectory: true))
    }

    // MARK: Connection
    public var connection: ProviderConnection?
    public var isConnecting = false
    public var isRestoring = true

    // MARK: Repos
    public var repos: [GitRepository] = []
    public var isLoadingRepos = false

    // MARK: Active board
    /// Boards (repos) the user has added — shown on the home screen. Persisted.
    public var addedRepos: [AddedRepo] = []
    public var activeBoardFolder: String?
    /// The open board's repo (nil = home list). Persisted so it reopens on launch.
    public var activeRepo: AddedRepo?
    public var workspace: Workspace?
    public var selectedProject: BoardProject?
    public var board: LoadedBoard?
    public var isLoadingBoard = false
    /// Set to ask the board screen for the open board's full settings (lanes, priorities, members).
    public var wantsProjectSettings = false
    /// Asked for from the sidebar's footer; the board screen shows the sheet.
    public var wantsNewProject = false
    public var wantsLiveUpdates = false
    public var isSaving = false

    // MARK: Agent access
    /// The port the agent server is listening on; `nil` when it is not running.
    public var agentServerPort: Int?
    /// Why the agent server is not running although it is turned on.
    public var agentServerError: String?

    // MARK: Presentation
    public var selectedCard: Card?
    public var newTaskLane: Lane?
    public var boardViewMode: BoardViewMode = .lanes
    public var showQuickCreate = false

    // MARK: AI Configuration
    public var aiProvider: AIPontProvider = .anthropic
    public var aiModel: String = AIPontProvider.anthropic.defaultModel
    public var aiAPIKey: String = ""
    public var isGeneratingTickets = false
    public var generatedTickets: [AIGeneratedTicket] = []
    public var aiError: String?

    // MARK: Filters + search
    public var filterAssignee: String?
    public var filterPriority: String?
    public var filterType: String?
    /// Show only the tasks of this product (a product id of the open board).
    public var filterProduct: String?
    /// The products the open board's README lists.
    public var products: [BoardProduct] = []
    public var isShowingSearch = false
    /// Notifications (see AppModel+Notifications.swift). Off until the app turns them on
    /// at launch: an extension or a test has no notification centre to talk to.
    @ObservationIgnored var notificationRouter: NotificationRouter?
    /// What the system allows: `nil` until asked.
    public internal(set) var notificationsAllowed: Bool?
    /// Counted up when a notification setting changes, so the settings screen redraws.
    var notificationSettingsVersion = 0
    /// A notification about reviews was tapped: show them.
    public var wantsReviews = false
    /// The Mac's detail area shows every board's reviews instead of a board.
    public var isShowingReviews = false
    /// The open board's documentation pages (see AppModel+Docs.swift).
    public var docs: [BoardDoc] = []
    public var isLoadingDocs = false
    /// True while the Mac shows the open board's pages in place of its lanes.
    public var isShowingDocs = false
    /// The detail pane shows the tasks of every board instead of one board.
    public var isShowingAllTasks = false
    /// The open tasks of each board in the sidebar (see `loadAllTasks`).
    public var allTasks: [BoardTasks] = []
    public var isLoadingAllTasks = false
    /// New boards found next to the ones in the sidebar, waiting for a yes or no.
    public var boardSuggestions: [BoardSuggestion] = []
    /// A task to select once its board is on screen (picked in All Tasks).
    @ObservationIgnored var pendingSelection: String?
    /// The board `docs` was read for.
    @ObservationIgnored var docsBoardKey: String?
    /// Folders of pages in other repositories that the open board links to.
    public var docSources: [DocSource] = []
    /// Linked folders that could not be read, with why.
    public var docSourceProblems: [String: String] = [:]
    /// What each board looked like when it was last on screen in this session, by
    /// "repoID|folder": going back to a board shows this at once while it is read again.
    @ObservationIgnored var boardCache: [String: CachedBoard] = [:]
    /// Default branches found for linked repositories, so each is asked once.
    @ObservationIgnored var docBranches: [String: String] = [:]
    /// The board ("repoID|folder") whose requests the reviews screen starts on, when it
    /// was opened from that board.
    public var reviewsFocusBoard: String?
    public var searchText = ""

    public var hasActiveFilters: Bool {
        filterAssignee != nil || filterPriority != nil || filterType != nil || filterProduct != nil
    }

    public func clearFilters() {
        filterAssignee = nil
        filterPriority = nil
        filterType = nil
        filterProduct = nil
    }

    public func matchesFilters(_ card: Card) -> Bool {
        if let filterAssignee, card.fields.assignee != filterAssignee { return false }
        if let filterPriority, card.fields.priority != filterPriority { return false }
        if let filterType, card.fields.type != filterType { return false }
        if let filterProduct, card.fields.product != filterProduct { return false }
        return true
    }

    /// Every card on the current board (all lanes + uncategorised).
    public var allCards: [Card] {
        (board?.columns.flatMap(\.cards) ?? []) + (board?.uncategorised ?? [])
    }

    // MARK: Status
    public var errorMessage: String?

    public var isConnected: Bool { connection != nil }

    // MARK: Persistence
    @ObservationIgnored private let keychain: KeychainService
    /// The pre-App-Group keychain item, read once to migrate (and as a fallback).
    @ObservationIgnored private let legacyKeychain: KeychainService?
    @ObservationIgnored let defaults: UserDefaults
    /// The MCP server agents connect to (see `AppModel+Agents.swift`).
    @ObservationIgnored var agentServer: MCPHTTPServer?
    @ObservationIgnored private let storageMigratedKey = "gitkanban.storageMigratedToGroup"
    @ObservationIgnored private let connectionKey = "gitkanban.connection"
    @ObservationIgnored let addedReposKey = "gitkanban.addedReposV2"
    @ObservationIgnored private let activeRepoKey = "gitkanban.activeRepo"
    @ObservationIgnored private let activeBoardKey = "gitkanban.activeBoard"
    @ObservationIgnored private let aiProviderKey = "gitkanban.aiProvider"
    @ObservationIgnored private let aiModelKey = "gitkanban.aiModel"
    @ObservationIgnored private let aiAPIKeyKey = "gitkanban.aiAPIKey"

    @ObservationIgnored var source: (any BoardWritable)?
    /// What a long settings save is doing right now (merging members rewrites tasks one by one).
    public var settingsProgress: String?
    /// True when viewing the offline in-memory demo board (no provider connection).
    public var isDemo = false

    // MARK: Folders & review state (see AppModel+Folders.swift)

    /// Review requests for the open board's project (empty when it has no `review_path` folder).
    public var reviews: [ReviewRequest] = []
    /// The source-relative folder the open board's reviews come from, if configured.
    public var reviewFolder: String?
    public var isLoadingReviews = false
    /// Review requests of every added board, per board (see AppModel+ReviewInbox.swift).
    public internal(set) var reviewInbox: [BoardReviews] = []
    public internal(set) var isLoadingReviewInbox = false
    /// Whether the inbox has been loaded at least once since launch.
    public internal(set) var hasLoadedReviewInbox = false
    /// Ids of the cards in the selected project that have files in `attachments/<id>/`.
    public internal(set) var attachmentCardIDs: Set<String> = []
    /// The signed-in identity reported by a folder server (`Tailscale-User-Login`).
    public var serverLogin: String?
    @ObservationIgnored var folderSourceCache: [String: any BoardWritable] = [:]
    @ObservationIgnored var watchTask: Task<Void, Never>?

    /// Set while a board is open transiently (the share extension): it was loaded without
    /// its cards, and this listing stands in for them when a free file name is needed.
    @ObservationIgnored var transientListing: BoardListing?
    /// Whether the transiently opened board's cards have been loaded after all.
    public private(set) var hasTransientCards = false

    /// A move to another project that is waiting for the id question (see AppModel+MoveProject.swift).
    public var pendingProjectMove: ProjectMovePlan?

    // MARK: Outbox (see AppModel+Sync.swift and Outbox.swift)

    @ObservationIgnored let outbox: Outbox
    @ObservationIgnored let readCache: ReadCache
    /// Writes that are waiting to be sent, being sent, or were refused. Oldest first.
    public internal(set) var syncItems: [OutboxOperation] = []
    /// The most recent writes that went out.
    public internal(set) var syncReceipts: [OutboxReceipt] = []
    public internal(set) var isSyncing = false

    // MARK: Seen state & sorting (see AppModel+Seen.swift)

    /// How cards are ordered inside a lane or stage.
    public var cardSort: CardSort = .board {
        didSet { defaults.set(cardSort.rawValue, forKey: "gitkanban.cardSort") }
    }
    /// When each card was last opened on this device (key = boardKey|cardID).
    public internal(set) var seenCards: [String: Date] = [:]
    /// When each board was first opened (or last marked all seen); older updates count as seen.
    public internal(set) var seenBaselines: [String: Date] = [:]
    /// Where each board's card files were when it was last looked at (file name → lane id).
    @ObservationIgnored var boardSnapshots: [String: [String: String]] = [:]
    /// Listing-based summaries for the boards list (key = repoID|folder).
    public internal(set) var boardSummaries: [String: BoardSummary] = [:]

    // MARK: - Lifecycle

    public func restore() async {
        defer { isRestoring = false }
        migrateLegacyStorageIfNeeded()
        loadAddedRepos()
        loadAIConfig()
        loadSeenState()
        await reconnect(loadRepositories: true)
        await refreshSyncItems()
        Task { await flushOutbox() }
        await reopenLastBoard()
    }

    /// Restore just enough to write a card from outside the app (the share extension):
    /// the added boards and the provider connection, without the repo list or reopening
    /// the last board.
    public func restoreForSharing() async {
        defer { isRestoring = false }
        loadAddedRepos()
        loadAIConfig()
        await reconnect(loadRepositories: false)
    }

    /// The board that was open last, if it is still added.
    public var lastOpenedBoard: (repo: AddedRepo, folder: String)? {
        guard let savedRepo = defaults.string(forKey: activeRepoKey),
              let repo = addedRepos.first(where: { $0.fullName == savedRepo }),
              let folder = defaults.string(forKey: activeBoardKey),
              repo.boards.contains(where: { $0.folder == folder }) else { return nil }
        return (repo, folder)
    }

    private func reconnect(loadRepositories: Bool) async {
        guard let data = defaults.data(forKey: connectionKey),
              let stored = try? JSONDecoder().decode(StoredConnection.self, from: data),
              let token = storedToken() else { return }
        // A connection restored before: trust what was stored and start working right
        // away, online or not. A token that stopped being valid shows up on first use.
        if let login = stored.login, let (instance, provider) = Self.provider(for: stored.choice, serverURL: stored.serverURL) {
            connection = ProviderConnection(choice: stored.choice, instance: instance, provider: provider, token: token, login: login)
            if loadRepositories { Task { await loadRepos() } }
            return
        }
        await connect(choice: stored.choice, serverURL: stored.serverURL, token: token,
                      persist: false, loadRepositories: loadRepositories)
    }

    private func storedToken() -> String? {
        for store in [keychain, legacyKeychain].compactMap({ $0 }) {
            if let token = ((try? store.load()) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty { return token }
        }
        return nil
    }

    /// Move what an earlier version kept in the app's private defaults and keychain item
    /// into the shared App Group storage. Runs once; an existing shared value always wins.
    /// The legacy token is only removed after the shared copy is written, and
    /// `storedToken()` still falls back to it, so a failed move never signs anyone out.
    private func migrateLegacyStorageIfNeeded() {
        guard let legacyKeychain, defaults !== UserDefaults.standard,
              !defaults.bool(forKey: storageMigratedKey) else { return }
        let legacyDefaults = UserDefaults.standard
        for key in [connectionKey, addedReposKey, activeRepoKey, activeBoardKey,
                    aiProviderKey, aiModelKey, aiAPIKeyKey] {
            if defaults.object(forKey: key) == nil, let value = legacyDefaults.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        if let token = (try? legacyKeychain.load()) ?? nil, !token.isEmpty {
            if ((try? keychain.load()) ?? nil) == nil {
                do { try keychain.save(token) } catch { return }  // retry on the next launch
            }
            try? legacyKeychain.delete()
        }
        defaults.set(true, forKey: storageMigratedKey)
    }

    /// Reopen the last board so relaunching lands where you left off. Folder entries
    /// reopen without a provider connection.
    private func reopenLastBoard() async {
        if let savedRepo = defaults.string(forKey: activeRepoKey),
           let repo = addedRepos.first(where: { $0.fullName == savedRepo }),
           repo.kind.isFolder || isConnected,
           let folder = defaults.string(forKey: activeBoardKey),
           repo.boards.contains(where: { $0.folder == folder }) {
            await openBoard(repo, folder: folder)
        }
    }

    // MARK: - Repos & boards

    func persistAddedRepos() {
        if let data = try? JSONEncoder().encode(addedRepos) { defaults.set(data, forKey: addedReposKey) }
    }
    private func loadAddedRepos() {
        guard let data = defaults.data(forKey: addedReposKey),
              let saved = try? JSONDecoder().decode([AddedRepo].self, from: data) else { return }
        addedRepos = saved
    }

    /// Add a repository (no boards yet). The caller then browses it to pick boards.
    @discardableResult
    public func addRepo(_ repo: GitRepository) -> AddedRepo {
        if let existing = addedRepos.first(where: { $0.fullName == "\(repo.reference.namespace)/\(repo.reference.name)" }) {
            return existing
        }
        let added = AddedRepo(
            namespace: repo.reference.namespace,
            name: repo.reference.name,
            branch: repo.reference.defaultBranch ?? "main",
            isPrivate: repo.isPrivate,
            boards: []
        )
        addedRepos.append(added)
        addedRepos.sort { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        persistAddedRepos()
        return added
    }

    public func removeAddedRepo(_ repo: AddedRepo) {
        addedRepos.removeAll { $0.id == repo.id }
        persistAddedRepos()
        if activeRepo?.id == repo.id { closeRepo() }
    }

    /// Set which boards are selected for a repo (from the browse/multi-select step).
    public func setBoards(_ boards: [SelectedBoard], for repoID: String) {
        guard let index = addedRepos.firstIndex(where: { $0.id == repoID }) else { return }
        addedRepos[index].boards = boards.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistAddedRepos()
    }

    /// Remove one board from a repo.
    public func removeBoard(_ board: SelectedBoard, from repo: AddedRepo) {
        guard let index = addedRepos.firstIndex(where: { $0.id == repo.id }) else { return }
        addedRepos[index].boards.removeAll { $0.id == board.id }
        persistAddedRepos()
    }

    /// A file source rooted at a repo's (or folder's) root — boards are addressed by folder.
    private func makeSource(for repo: AddedRepo) -> (any BoardWritable)? {
        if repo.kind.isFolder { return folderSource(for: repo) }
        guard let remote = remoteSource(for: repo) else { return nil }
        return OutboxSource(base: remote, outbox: outbox, repoKey: repo.id, branch: repo.branch, cache: readCache) { [weak self] in
            Task { @MainActor in self?.outboxDidChange() }
        }
    }

    /// The provider itself, with nothing in between: what the outbox sends through.
    func remoteSource(for repo: AddedRepo) -> (any BoardWritable)? {
        guard !repo.kind.isFolder, let connection else { return nil }
        return GitPontFileSource(
            provider: connection.provider, instance: connection.instance,
            owner: repo.namespace, repo: repo.name, branch: repo.branch, token: connection.token)
    }

    public func boardCount(_ repo: AddedRepo, _ folder: String) -> Int? { boardSummaries["\(repo.id)|\(folder)"]?.total }

    /// Lazily summarize a board for the boards list (once per launch, then cached).
    public func loadBoardCount(_ repo: AddedRepo, _ folder: String) async {
        await loadBoardSummary(repo, folder, force: false)
    }

    func source(for repo: AddedRepo) -> (any BoardWritable)? { makeSource(for: repo) }

    /// The subfolders under a repo-relative path (`""` = repo root) — for browsing to
    /// pick board folders yourself, no scanning/heuristics.
    public func listFolders(in repo: AddedRepo, at path: String) async -> [BoardFileEntry] {
        guard let source = makeSource(for: repo) else { return [] }
        let entries = (try? await source.list(path)) ?? []
        return entries
            .filter { $0.kind == .directory && !$0.name.hasPrefix(".") && $0.name != "node_modules" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Whether the open board looks unconfigured — cards exist but no lane matched them.
    public var boardNeedsSetup: Bool {
        guard let board else { return false }
        return board.config.lanes.isEmpty && !board.uncategorised.isEmpty
    }

    /// Infer a project config for a board from its folder structure and card fields:
    /// each subfolder becomes a lane (status from the cards, or the folder name), and
    /// priorities/types/members/epics are collected from the cards. Used to prefill the
    /// setup sheet; saving writes it into the board's README.
    public func detectConfig(for project: BoardProject) async -> DetectedBoardConfig {
        guard let source else { return DetectedBoardConfig() }
        let entries = (try? await source.list(project.folder)) ?? []
        let subdirs = entries
            .filter { $0.kind == .directory && !$0.name.hasPrefix(".") && $0.name != "attachments" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var lanes: [Lane] = []
        var priorities = Set<String>(), types = Set<String>(), members = Set<String>(), epics = Set<String>()

        for dir in subdirs {
            let cards = (try? await RemoteBoardStore.cards(source: source, dir: dir.path)) ?? []
            let name = prettyLaneName(dir.name)
            let statuses = cards.compactMap { $0.fields.status.isEmpty ? nil : $0.fields.status }
            let common = Dictionary(grouping: statuses, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            let status = common ?? slug(name)
            let isBacklog = dir.name.lowercased().contains("backlog") || status.lowercased().contains("backlog")
            lanes.append(Lane(id: status, name: name, folder: dir.name, status: status, terminal: nil, backlog: isBacklog ? true : nil))
            for card in cards {
                if let p = card.fields.priority, !p.isEmpty { priorities.insert(p) }
                if let t = card.fields.type, !t.isEmpty { types.insert(t) }
                if let a = card.fields.assignee, !a.isEmpty { members.insert(a) }
                if let e = card.fields.epic, !e.isEmpty { epics.insert(e) }
            }
        }
        return DetectedBoardConfig(
            lanes: lanes,
            priorities: priorities.sorted().map { Priority(id: $0) },
            users: members.sorted().map { User(id: $0) },
            types: types.sorted(),
            epics: epics.sorted().map { Epic(id: $0) }
        )
    }

    /// Strip a leading "N. " ordering prefix from a lane folder name.
    private func prettyLaneName(_ folder: String) -> String {
        if let range = folder.range(of: "^\\s*\\d+\\.?\\s*", options: .regularExpression) {
            let stripped = String(folder[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return stripped }
        }
        return folder
    }

    // MARK: - Connect

    /// Validate a token against the chosen provider, then load its repositories.
    public func connect(choice: ProviderChoice, serverURL rawServerURL: String?, token rawToken: String,
                        persist: Bool = true, loadRepositories: Bool = true) async {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { errorMessage = "Enter a personal access token."; return }

        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        guard let (instance, provider) = Self.provider(for: choice, serverURL: rawServerURL) else {
            errorMessage = "Enter a valid GitLab server URL."
            return
        }

        await establish(choice: choice, instance: instance, provider: provider, token: token,
                        serverURL: rawServerURL, persist: persist, loadRepositories: loadRepositories)
    }

    static func provider(for choice: ProviderChoice, serverURL rawServerURL: String?) -> (GitProviderInstance, any GitProvider)? {
        switch choice {
        case .github:
            return (.github, GitHubProvider(httpClient: UncachedHTTPClient()))
        case .gitlabCloud:
            return (.gitLabCloud, GitLabProvider(httpClient: UncachedHTTPClient(), instances: [.gitLabCloud]))
        case .gitlabSelfHosted:
            guard let raw = rawServerURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  let url = URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)") else { return nil }
            let instance = GitProviderInstance.gitLabSelfHosted(baseURL: url)
            return (instance, GitLabProvider(httpClient: UncachedHTTPClient(), instances: [instance]))
        }
    }

    /// Validate a token/credential against a provider, set the active connection,
    /// persist it, and load repositories. Shared by the token and OAuth connect paths.
    private func establish(
        choice: ProviderChoice, instance: GitProviderInstance, provider: any GitProvider,
        token: String, serverURL: String?, persist: Bool, loadRepositories: Bool = true
    ) async {
        do {
            let account = try await provider.account(instance: instance, credential: GitCredential(accessToken: token))
            connection = ProviderConnection(
                choice: choice, instance: instance, provider: provider, token: token, login: account.login
            )
            if persist { try? keychain.save(token) }
            // The login is kept so the next launch can restore the connection without a
            // round-trip (and so with no connection at all).
            let stored = StoredConnection(choice: choice, serverURL: serverURL, login: account.login)
            if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: connectionKey) }
            if loadRepositories { await loadRepos() }
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
        }
    }

    // MARK: - GitHub OAuth (device flow)

    /// The active GitHub device-flow session (user code + verification URL) while the
    /// user authorises in a browser. Non-nil means the Connect screen shows the code.
    public var deviceAuth: GitOAuthDeviceSession?

    @ObservationIgnored private let gitHubOAuthConfig = OAuthAppConfig(
        clientID: "Ov23li24tWFt7qLuLqCe", scopes: ["repo"]
    )

    /// Begin GitHub sign-in with the OAuth device flow: request a user code, surface it
    /// for the browser, then poll until the user authorises.
    public func startGitHubOAuth() async {
        errorMessage = nil
        isConnecting = true
        let provider = GitHubProvider(httpClient: UncachedHTTPClient(), oauth: gitHubOAuthConfig)
        do {
            let result = try await provider.startOAuth(GitOAuthStartRequest(
                instance: .github, method: .oauthDevice, appConfig: gitHubOAuthConfig))
            guard case let .device(session) = result else {
                errorMessage = "Unexpected OAuth response from GitHub."
                isConnecting = false
                return
            }
            deviceAuth = session
            await pollGitHubOAuth(provider: provider, session: session)
        } catch {
            errorMessage = "Could not start sign-in: \(error.localizedDescription)"
            isConnecting = false
        }
    }

    public func cancelOAuth() {
        deviceAuth = nil
        isConnecting = false
    }

    private func pollGitHubOAuth(provider: GitHubProvider, session: GitOAuthDeviceSession) async {
        var interval = max(session.interval, 5)
        while Date() < session.expiresAt {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if deviceAuth == nil { return } // cancelled by the user
            do {
                let credential = try await provider.completeOAuth(GitOAuthCompletionRequest(
                    instance: .github, method: .oauthDevice, appConfig: gitHubOAuthConfig,
                    deviceCode: session.deviceCode))
                deviceAuth = nil
                await establish(choice: .github, instance: .github, provider: provider,
                                token: credential.accessToken, serverURL: nil, persist: true)
                isConnecting = false
                return
            } catch GitPontError.authenticationFailed(let message) {
                let m = message.lowercased()
                if m.contains("slow") { interval += 5 }
                if m.contains("denied") || m.contains("declined") { finishOAuth(error: "Sign-in was declined on GitHub."); return }
                if m.contains("expired") { finishOAuth(error: "The code expired. Please try again."); return }
                continue  // authorization_pending / transient: keep waiting
            } catch {
                continue  // transient (e.g. network) — keep the screen and poll again
            }
        }
        finishOAuth(error: "Sign-in timed out. Please try again.")
    }

    private func finishOAuth(error: String) {
        guard deviceAuth != nil else { return }
        deviceAuth = nil
        isConnecting = false
        errorMessage = error
    }

    public func signOut() {
        try? keychain.delete()
        defaults.removeObject(forKey: connectionKey)
        defaults.removeObject(forKey: activeRepoKey)
        defaults.removeObject(forKey: activeBoardKey)
        connection = nil
        repos = []
        // Folder entries don't depend on the provider account, so they stay.
        addedRepos.removeAll { !$0.kind.isFolder }
        persistAddedRepos()
        stopWatching()
        activeRepo = nil
        activeBoardFolder = nil
        workspace = nil
        selectedProject = nil
        board = nil
        source = nil
    }

    // MARK: - Repos

    public func loadRepos() async {
        guard let connection else { return }
        isLoadingRepos = true
        errorMessage = nil
        defer { isLoadingRepos = false }
        do {
            let list = try await connection.provider.repositories(context: connection.requestContext)
            // Most-recently-updated first, so active repos stay on top.
            repos = list.items.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        } catch where Outbox.isConnectivity(error) {
            // Offline: the added boards still work; the repo list just isn't fresh.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func fullName(_ repo: GitRepository) -> String {
        "\(repo.reference.namespace)/\(repo.reference.name)"
    }

    // MARK: - Open a board

    /// Open a specific board (project folder) within a repo.
    /// `transient` opens it for a one-off write (the share extension): it is not remembered
    /// as the last board, and reviews and change-watching are skipped.
    public func openBoard(_ repo: AddedRepo, folder: String, transient: Bool = false) async {
        guard let source = makeSource(for: repo) else {
            if transient { errorMessage = "Open the app and sign in to use this board." }
            return
        }
        let key = "\(repo.id)|\(folder)"
        // Another board: keep what the one on screen had loaded, and show what this one
        // had the last time, so switching back and forth does not start from nothing.
        var remembered: CachedBoard?
        if activeRepo?.id != repo.id || activeBoardFolder != folder {
            rememberOpenBoard()
            // A product filter belongs to the board it was set on.
            filterProduct = nil
            products = []
            remembered = transient ? nil : boardCache[key]
            board = remembered?.board
            selectedProject = remembered?.project
            if let remembered {
                workspace = remembered.workspace
                docs = remembered.docs
                docSources = remembered.docSources
                products = remembered.products
                docSourceProblems = [:]
                docsBoardKey = key
            }
        }
        activeRepo = repo
        activeBoardFolder = folder
        self.source = source
        errorMessage = nil
        loadedBacklogLanes = remembered?.loadedBacklogLanes ?? []
        isLoadingBoard = true
        defer { isLoadingBoard = false }
        if !transient {
            defaults.set(repo.fullName, forKey: activeRepoKey)
            defaults.set(folder, forKey: activeBoardKey)
        }
        transientListing = nil
        hasTransientCards = false
        do {
            if transient {
                // Lanes and file names only: reading every card is one request each over
                // a provider API, and filing a new card needs none of them.
                let shell = try await RemoteBoardStore.loadBoardShell(source: source, folder: folder)
                workspace = Workspace(rootConfig: shell.rootConfig, projects: [shell.project])
                selectedProject = shell.project
                board = shell.board
                transientListing = shell.listing
            } else {
                var loaded = try await RemoteBoardStore.loadBoard(source: source, folder: folder, loadBacklog: false)
                // A backlog lane that was loaded before stays loaded: this read skips it.
                if let before = remembered?.board ?? (board?.columns.isEmpty == false ? board : nil) {
                    for index in loaded.board.columns.indices where loadedBacklogLanes.contains(loaded.board.columns[index].lane.id) {
                        if let old = before.columns.first(where: { $0.lane.id == loaded.board.columns[index].lane.id }) {
                            loaded.board.columns[index].cards = old.cards
                        }
                    }
                }
                let fresh = Workspace(rootConfig: loaded.rootConfig, projects: [loaded.project])
                // Another board was opened while this one was being read: keep the result
                // for when it is opened again, and leave the screen alone.
                guard activeRepo?.id == repo.id, activeBoardFolder == folder else {
                    boardCache[key] = CachedBoard(workspace: fresh, project: loaded.project, board: loaded.board,
                                                  loadedBacklogLanes: remembered?.loadedBacklogLanes ?? [],
                                                  docs: remembered?.docs ?? [], docSources: remembered?.docSources ?? [])
                    return
                }
                // A single-project workspace, so edit/reload paths keep working.
                workspace = fresh
                selectedProject = loaded.project
                board = loaded.board
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        guard !transient else { return }
        await loadProducts()
        if board != nil { await boardWasOpened(repo, folder: folder) }
        await loadReviews()
        startWatching()
    }

    /// Keep the board that is on screen for when it is opened again.
    func rememberOpenBoard() {
        guard let repo = activeRepo, let folder = activeBoardFolder, let workspace, let project = selectedProject, let board,
              transientListing == nil, !isDemo else { return }
        let key = "\(repo.id)|\(folder)"
        boardCache[key] = CachedBoard(workspace: workspace, project: project, board: board, loadedBacklogLanes: loadedBacklogLanes,
                                      docs: docsBoardKey == key ? docs : [], docSources: docsBoardKey == key ? docSources : [], products: products)
        // Only a handful: a board with hundreds of cards is not small.
        if boardCache.count > 8, let oldest = boardCache.keys.first(where: { $0 != key }) { boardCache[oldest] = nil }
    }

    /// Load the cards of a transiently opened board after all (to pick an existing card).
    public func loadTransientCards() async {
        guard transientListing != nil, !hasTransientCards, let source, let project = selectedProject,
              let rootConfig = workspace?.rootConfig else { return }
        isLoadingBoard = true
        defer { isLoadingBoard = false }
        do {
            board = try await RemoteBoardStore.loadProjectBoard(
                source: source, project: project, rootConfig: rootConfig, loadBacklog: false)
            hasTransientCards = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Load the offline in-memory demo board — explore the app without connecting.
    public func loadDemo() async {
        isDemo = true
        isRestoring = false
        errorMessage = nil
        isLoadingBoard = true
        defer { isLoadingBoard = false }
        source = InMemoryBoardSource.demo()
        await loadWorkspaceAndFirstProject()
    }

    private func loadWorkspaceAndFirstProject() async {
        guard let source else { return }
        do {
            let workspace = try await RemoteBoardStore.loadWorkspace(source: source)
            self.workspace = workspace
            if let first = workspace.projects.first {
                await selectProject(first)
            } else {
                selectedProject = nil
                board = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Backlog lanes whose cards have been lazily loaded (they're skipped on first load).
    public var loadedBacklogLanes: Set<String> = []
    public var loadingBacklogLane: String?

    public func selectProject(_ project: BoardProject) async {
        guard let source, let workspace else { return }
        isLoadingBoard = true
        defer { isLoadingBoard = false }
        loadedBacklogLanes = []
        do {
            board = try await RemoteBoardStore.loadProjectBoard(
                source: source, project: project, rootConfig: workspace.rootConfig, loadBacklog: false
            )
            selectedProject = project
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadReviews()
    }

    /// Lazily load a backlog lane's cards on demand.
    public func loadBacklogLane(_ lane: Lane) async {
        guard let source, let project = selectedProject, let rootConfig = workspace?.rootConfig, var board else { return }
        loadingBacklogLane = lane.id
        defer { loadingBacklogLane = nil }
        let cards = (try? await RemoteBoardStore.loadLaneCards(
            source: source, project: project, lane: lane, rootConfig: rootConfig)) ?? []
        if let index = board.columns.firstIndex(where: { $0.lane.id == lane.id }) {
            board.columns[index].cards = cards
            self.board = board
        }
        loadedBacklogLanes.insert(lane.id)
    }

    public func closeRepo() {
        stopWatching()
        reviews = []
        reviewFolder = nil
        activeRepo = nil
        activeBoardFolder = nil
        workspace = nil
        selectedProject = nil
        board = nil
        source = nil
        isDemo = false
        clearFilters()
        defaults.removeObject(forKey: activeRepoKey)
        defaults.removeObject(forKey: activeBoardKey)
    }

    // MARK: - Projects (board settings)

    /// Default 5 lanes for a new project.
    public static func defaultProjectLanes() -> [Lane] {
        lanes(fromNames: ["To do", "In Progress", "In Review", "Testing", "Done"], terminalLast: true)
    }
    public static func defaultPriorities() -> [Priority] { (0...3).map { Priority(id: "P\($0)") } }

    /// Build lanes from display names: folder = "<n>. <name>", id/status = slug.
    public static func lanes(fromNames names: [String], terminalLast: Bool = false) -> [Lane] {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.enumerated().map { index, name in
            let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
            return Lane(id: slug, name: name, folder: "\(index + 1). \(name)", status: slug,
                        terminal: (terminalLast && index == cleaned.count - 1) ? true : nil)
        }
    }

    /// Create a project: write its README config (one commit). Lanes render from config,
    /// so empty lane folders aren't needed — they're created on the first task add.
    public func createProject(name rawName: String, description: String, lanes: [Lane],
                       priorities: [Priority], users: [User], epics: [Epic]) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source else { return }
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
            errorMessage = "A project needs a name without slashes."; return
        }
        let readme = BoardStore.renderProjectReadme(
            name: name, description: description, lanes: lanes,
            priorities: priorities, users: users, types: [], epics: epics)
        isSaving = true; errorMessage = nil
        do { try await source.write(path: "\(name)/README.md", text: readme, message: "Create project \(name)") }
        catch { errorMessage = error.localizedDescription }
        isSaving = false
        // Add the new project as a board of the active repo and open it.
        if let repo = activeRepo {
            if let i = addedRepos.firstIndex(where: { $0.id == repo.id }),
               !addedRepos[i].boards.contains(where: { $0.folder == name }) {
                addedRepos[i].boards.append(SelectedBoard(folder: name, name: name))
                persistAddedRepos()
            }
            await openBoard(repo, folder: name)
        } else {
            await reloadWorkspace(selecting: name)
        }
    }

    /// Save a project's settings by rewriting its README config (one commit).
    public func saveProjectSettings(project: BoardProject, name: String, description: String, lanes: [Lane],
                            priorities: [Priority], users: [User], types: [String], epics: [Epic],
                            appearance: (icon: String?, color: String?)? = nil,
                            merges: [FieldMerge] = []) async {
        guard let source else { return }
        let path = project.folder.isEmpty ? "README.md" : "\(project.folder)/README.md"
        // The form only knows ids and names. What the board holds beyond that (a member's
        // role, an epic's description) is kept for every id that is still there.
        let known = board?.config
        let fullUsers = users.map { user in known?.users.first { $0.id == user.id } ?? user }
        let fullPriorities = priorities.map { priority in known?.priorities.first { $0.id == priority.id } ?? priority }
        let fullEpics = epics.map { epic -> Epic in
            guard var existing = known?.epics.first(where: { $0.id == epic.id }) else { return epic }
            existing.name = epic.name
            return existing
        }
        func render(_ lanes: [Lane], _ priorities: [Priority], _ users: [User], _ types: [String], _ epics: [Epic]) -> String {
            BoardStore.renderProjectReadme(name: name, description: description, lanes: lanes,
                                           priorities: priorities, users: users, types: types, epics: epics)
        }
        let rendered = render(lanes, fullPriorities, fullUsers, types, fullEpics)
        let managed = ["project", "lanes", "priorities", "users", "types", "epics"]
        let readme: String
        if let original = try? await source.readText(path), !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A part the board inherits, and that was not changed here, stays inherited:
            // it is not copied into this README.
            var unchanged = Set<String>()
            if let known {
                let before = ReadmePatch.blocks(BoardMarkdown.splitFrontmatter(
                    render(known.lanes, known.priorities, known.users, known.types, known.epics)).frontmatter ?? "")
                let after = ReadmePatch.blocks(BoardMarkdown.splitFrontmatter(rendered).frontmatter ?? "")
                let own = Set(ReadmePatch.blocks(BoardMarkdown.splitFrontmatter(original).frontmatter ?? "").map(\.key))
                // A board that never named itself keeps going by its folder's name.
                if !own.contains("project"), name == project.name { unchanged.insert("project") }
                for key in managed where key != "project" && !own.contains(key) {
                    if before.first(where: { $0.key == key }) == after.first(where: { $0.key == key }) { unchanged.insert(key) }
                }
            }
            // Only the parts the settings window edits are replaced. The README's text,
            // its linked docs and any other key stay exactly as they are.
            let patched = ReadmePatch.apply(rendered, to: original, keys: managed, unchanged: unchanged)
            readme = appearance.map { CardText.update(patched, set: ["icon": $0.icon, "color": $0.color]) } ?? patched
        } else {
            readme = CardText.update(rendered, set: ["icon": appearance.map(\.icon) ?? project.config.icon,
                                                    "color": appearance.map(\.color) ?? project.config.color,
                                                    "review_path": project.config.reviewPath])
        }
        isSaving = true; errorMessage = nil
        do { try await source.write(path: path, text: readme, message: "Update \(name) settings") }
        catch { errorMessage = error.localizedDescription }
        // Tasks follow a merged value only once the README itself is saved.
        if errorMessage == nil { await mergeValues(merges, in: project) }
        isSaving = false
        // Reload the open board with its new config (lanes now match the cards).
        if let repo = activeRepo, let folder = activeBoardFolder, folder == project.folder {
            if let ri = addedRepos.firstIndex(where: { $0.id == repo.id }),
               let bi = addedRepos[ri].boards.firstIndex(where: { $0.folder == folder }) {
                addedRepos[ri].boards[bi].name = name
                if let appearance {
                    addedRepos[ri].boards[bi].icon = appearance.icon
                    addedRepos[ri].boards[bi].color = appearance.color
                }
                persistAddedRepos()
            }
            boardSummaries["\(repo.id)|\(folder)"] = nil
            await openBoard(repo, folder: folder)
        } else {
            await reloadWorkspace(selecting: project.folder)
        }
    }

    /// Reload the workspace and select the project with the given folder (or the first).
    private func reloadWorkspace(selecting folder: String) async {
        guard let source else { return }
        do {
            let workspace = try await RemoteBoardStore.loadWorkspace(source: source)
            self.workspace = workspace
            let project = workspace.projects.first { $0.folder == folder } ?? workspace.projects.first
            if let project { await selectProject(project) }
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Writes (over the provider API via git-pont)

    /// Returns the new card's id, or `nil` when it was not written (see `errorMessage`).
    @discardableResult
    public func createTask(
        title rawTitle: String, lane: Lane,
        priority: String?, type: String?, assignee: String?, epic: String? = nil, product: String? = nil, body: String
    ) async -> String? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source, let project = selectedProject, !title.isEmpty, !lane.folder.isEmpty else { return nil }
        // Ask the repository which cards exist now: an agent may have added some since
        // the board was loaded, and a skipped backlog lane holds numbers too. Offline,
        // what is known here has to do.
        let listed = (try? await RemoteBoardStore.listing(source: source, folder: project.folder))
            .map { Array($0.files.values.joined()) } ?? []
        // A product with a prefix of its own numbers its tasks with it.
        let ownPrefix = products.first { $0.id == product }?.prefix
        let (id, fileName) = newCardName(for: title, lane: lane, alsoTaken: listed, prefix: ownPrefix)
        let path = "\(project.folder)/\(lane.folder)/\(fileName)"
        var content = CardText.make(
            id: id, title: title, project: project.name, status: lane.status,
            priority: priority, type: type, assignee: assignee, body: body
        )
        if let epic, !epic.isEmpty { content = CardText.update(content, set: ["epic": epic]) }
        if let product, !product.isEmpty { content = CardText.update(content, set: ["product": product]) }
        await performWrite { try await source.write(path: path, text: content, message: "Add task \(id)") }
        guard errorMessage == nil else { return nil }
        transientListing?.files[lane.id, default: []].append(fileName)
        return id
    }

    public func moveCard(_ card: Card, to lane: Lane) async {
        guard let source, let project = selectedProject,
              let location = location(of: card), let fileName = card.fileName,
              location.lane.id != lane.id, !lane.folder.isEmpty else { return }

        // Optimistic: move the card between columns in memory right away so a drag lands
        // instantly; the git commit runs in the background and reverts on failure.
        if var board, let srcIdx = board.columns.firstIndex(where: { $0.lane.id == location.lane.id }),
           let dstIdx = board.columns.firstIndex(where: { $0.lane.id == lane.id }),
           let cardIdx = board.columns[srcIdx].cards.firstIndex(where: { $0.fields.id == card.fields.id }) {
            var moved = board.columns[srcIdx].cards.remove(at: cardIdx)
            moved.fields.status = lane.status
            board.columns[dstIdx].cards.append(moved)
            self.board = board
        }

        let original = (try? await source.readText(location.path)) ?? card.body
        let updated = CardText.update(original, set: ["status": lane.status])
        let newPath = "\(project.folder)/\(lane.folder)/\(fileName)"
        let message = "Move \(card.fields.id) to \(lane.name)"
        isSaving = true
        errorMessage = nil
        do {
            try await source.write(path: newPath, text: updated, message: message)
            try await source.delete(path: location.path, message: message)
        } catch {
            errorMessage = error.localizedDescription
            if let project = selectedProject { await selectProject(project) } // revert
        }
        isSaving = false
    }

    public func updateCard(
        _ card: Card, title: String, laneID: String,
        priority: String, type: String, assignee: String, epic: String = "", body: String
    ) async {
        guard let source, let project = selectedProject,
              let location = location(of: card), let fileName = card.fileName else { return }
        let lane = board?.config.lanes.first { $0.id == laneID } ?? location.lane
        let original = (try? await source.readText(location.path)) ?? card.body
        let updated = CardText.update(original, set: [
            "title": title,
            "status": lane.status,
            "priority": priority.isEmpty ? nil : priority,
            "type": type.isEmpty ? nil : type,
            "assignee": assignee.isEmpty ? nil : assignee,
            "epic": epic.isEmpty ? nil : epic,
        ], body: body)
        let moved = lane.id != location.lane.id
        let newPath = moved ? "\(project.folder)/\(lane.folder)/\(fileName)" : location.path
        await performWrite {
            try await source.write(path: newPath, text: updated, message: "Update \(card.fields.id)")
            if moved { try await source.delete(path: location.path, message: "Update \(card.fields.id)") }
        }
    }

    /// Add text to the end of a card's description, keeping everything else as it is.
    /// Returns false when it was not written (see `errorMessage`).
    @discardableResult
    public func appendToCard(_ card: Card, text: String) async -> Bool {
        guard let source, let location = location(of: card) else { return false }
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return true }
        let existing = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = existing.isEmpty ? addition : "\(existing)\n\n\(addition)"
        await performWrite {
            let original = try await source.readText(location.path)
            try await source.write(path: location.path, text: CardText.update(original, set: [:], body: body),
                                   message: "Update \(card.fields.id)")
        }
        return errorMessage == nil
    }

    public func deleteCard(_ card: Card) async {
        guard let source, let location = location(of: card) else { return }
        await performWrite { try await source.delete(path: location.path, message: "Delete \(card.fields.id)") }
    }

    /// Update one or more frontmatter fields on a card in place (no lane move).
    public func setCardField(_ card: Card, _ updates: [String: String?]) async {
        guard let source, let location = location(of: card) else { return }
        let original = (try? await source.readText(location.path)) ?? card.body
        let updated = CardText.update(original, set: updates)
        await performWrite { try await source.write(path: location.path, text: updated, message: "Update \(card.fields.id)") }
    }

    /// Duplicate a card into the same lane with a fresh id.
    public func duplicateCard(_ card: Card) async {
        guard let source, let project = selectedProject, let location = location(of: card) else { return }
        let original = (try? await source.readText(location.path)) ?? card.body
        let base = card.fields.title.isEmpty ? "task" : card.fields.title
        let newID = uniqueID(for: base, lane: location.lane)
        let newPath = "\(project.folder)/\(location.lane.folder)/\(newID).md"
        let content = CardText.update(original, set: ["id": newID])
        await performWrite { try await source.write(path: newPath, text: content, message: "Duplicate \(card.fields.id)") }
    }

    // MARK: - Attachments
    //
    // Files attached to a card live in a per-project folder namespaced by card id:
    // <project>/attachments/<cardId>/<filename>. They're committed to the repo (so they
    // show on GitHub by browsing that folder) and listed in the card detail.

    private func attachmentsDir(for card: Card) -> String? { attachmentsDir(forCardID: card.fields.id) }

    private func attachmentsDir(forCardID id: String) -> String? {
        guard let project = selectedProject else { return nil }
        return "\(project.folder)/attachments/\(id)"
    }

    /// The files attached to a card.
    public func attachments(for card: Card) async -> [BoardFileEntry] {
        guard let source, let dir = attachmentsDir(for: card) else { return [] }
        let entries = (try? await source.list(dir)) ?? []
        return entries.filter { $0.kind == .file }.sorted { $0.name < $1.name }
    }

    /// Attach a file to a card (committed to its attachments folder).
    @discardableResult
    public func attachFile(to card: Card, data: Data, filename: String) async -> Bool {
        await attachFile(toCardID: card.fields.id, data: data, filename: filename)
    }

    /// Attach a file by card id — for a card that was just created and isn't loaded yet.
    @discardableResult
    public func attachFile(toCardID cardID: String, data: Data, filename: String) async -> Bool {
        guard let source, let dir = attachmentsDir(forCardID: cardID) else { return false }
        let safe = filename.map { $0.isLetter || $0.isNumber || "._- ".contains($0) ? $0 : "-" }
        let name = String(safe).trimmingCharacters(in: .whitespaces)
        isSaving = true; errorMessage = nil; defer { isSaving = false }
        do {
            try await source.writeData(path: "\(dir)/\(name)", data: data, message: "Attach \(name) to \(cardID)")
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    public func deleteAttachment(path: String) async {
        guard let source else { return }
        isSaving = true; errorMessage = nil; defer { isSaving = false }
        try? await source.delete(path: path, message: "Remove attachment \(path)")
    }

    public func readAttachment(path: String) async -> Data? {
        guard let source else { return nil }
        return try? await source.readData(path)
    }

    /// The github.com blob URL for a card's file (Copy Link / Open on GitHub).
    public func githubURL(for card: Card) -> URL? {
        guard connection?.choice == .github, let repo = activeRepo, repo.kind == .provider, let location = location(of: card) else { return nil }
        let encoded = location.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? location.path
        return URL(string: "https://github.com/\(repo.namespace)/\(repo.name)/blob/\(repo.branch)/\(encoded)")
    }

    /// Persist a new within-lane order by rewriting each card's `order` frontmatter.
    /// Only cards whose order actually changed are committed.
    public func reorderCards(in lane: Lane, orderedIDs: [String]) async {
        guard let source, let project = selectedProject, let board,
              let column = board.columns.first(where: { $0.lane.id == lane.id }) else { return }
        let byID = Dictionary(uniqueKeysWithValues: column.cards.map { ($0.fields.id, $0) })
        isSaving = true
        errorMessage = nil
        do {
            for (index, id) in orderedIDs.enumerated() {
                guard let card = byID[id], let fileName = card.fileName else { continue }
                let newOrder = String(index + 1)
                if card.fields.order == newOrder { continue }
                let path = "\(project.folder)/\(lane.folder)/\(fileName)"
                let original = (try? await source.readText(path)) ?? card.body
                let updated = CardText.update(original, set: ["order": newOrder])
                try await source.write(path: path, text: updated, message: "Reorder \(id)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
        await selectProject(project)
    }

    /// Put a task at a place in a lane: before the task `beforeID`, or at the end when that
    /// is nil. Covers both a move to another lane and a reorder inside one, and saves it as
    /// one commit where the source can.
    public func placeCard(_ card: Card, in lane: Lane, before beforeID: String?) async {
        guard let source, let project = selectedProject, var board,
              let location = location(of: card), !lane.folder.isEmpty,
              let from = board.columns.firstIndex(where: { $0.lane.id == location.lane.id }),
              let to = board.columns.firstIndex(where: { $0.lane.id == lane.id }),
              beforeID != card.fields.id else { return }
        let id = card.fields.id
        let crossing = location.lane.id != lane.id

        var target = board.columns[to].cards.filter { $0.fields.id != id }
        let index = beforeID.flatMap { before in target.firstIndex { $0.fields.id == before } } ?? target.count
        // Dropped where it already is: nothing to save.
        if !crossing, board.columns[to].cards.firstIndex(where: { $0.fields.id == id }) == index { return }

        var moved = card
        moved.fields.status = lane.status
        target.insert(moved, at: index)
        let orders = Self.orders(placing: index, in: target.map(\.fields.order))
        for (position, order) in orders { target[position].fields.order = order }

        // Optimistic: the task is in its new place before the commit is made.
        board.columns[from].cards.removeAll { $0.fields.id == id }
        board.columns[to].cards = target
        self.board = board

        isSaving = true
        errorMessage = nil
        do {
            var texts: [String: String] = [:]
            for (position, order) in orders {
                let changed = target[position]
                guard let name = changed.fileName else { continue }
                let isMoved = changed.fields.id == id
                let readPath = isMoved ? location.path : "\(project.folder)/\(lane.folder)/\(name)"
                let original = (try? await source.readText(readPath)) ?? changed.body
                var fields: [String: String?] = ["order": order]
                if isMoved, crossing { fields["status"] = lane.status }
                texts["\(project.folder)/\(lane.folder)/\(name)"] = CardText.update(original, set: fields)
            }
            let message = crossing ? "Move \(id) to \(lane.name)" : "Reorder \(id)"
            let asOne = try await (source as? any BatchWritable)?.writeTexts(texts, message: message) ?? false
            if !asOne {
                for (path, text) in texts.sorted(by: { $0.key < $1.key }) {
                    try await source.write(path: path, text: text, message: message)
                }
            }
            if crossing { try await source.delete(path: location.path, message: message) }
        } catch {
            errorMessage = error.localizedDescription
            if let project = selectedProject { await selectProject(project) } // revert
        }
        isSaving = false
    }

    /// The `order` values to write so the task at `index` sorts where it was put, keyed by
    /// position. Between two numbered neighbours that is one value (their midpoint); in a
    /// lane that is not numbered yet, every task gets its position.
    nonisolated static func orders(placing index: Int, in existing: [String?]) -> [Int: String] {
        let others = existing.enumerated().filter { $0.offset != index }.map { $0.element.flatMap(Double.init) }
        let numbered = others.compactMap { $0 }
        let ordered = numbered.count == others.count && zip(numbered, numbered.dropFirst()).allSatisfy { $0 < $1 }
        if ordered {
            let before = index > 0 ? numbered[index - 1] : nil
            let after = index < numbered.count ? numbered[index] : nil
            let value: Double = switch (before, after) {
            case let (b?, a?): (b + a) / 2
            case let (b?, nil): b.rounded(.down) + 1
            case let (nil, a?): a.rounded(.up) - 1
            case (nil, nil): 1
            }
            let text = value == value.rounded() ? String(Int(value)) : String(format: "%.4f", value)
                .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            // Only when the midpoint is still a value of its own; otherwise renumber below.
            if let parsed = Double(text), before.map({ $0 < parsed }) ?? true, after.map({ parsed < $0 }) ?? true {
                return [index: text]
            }
        }
        var all: [Int: String] = [:]
        for position in existing.indices where existing[position] != String(position + 1) {
            all[position] = String(position + 1)
        }
        return all
    }

    // MARK: Write helpers

    func performWrite(_ operation: @escaping () async throws -> Void) async {
        guard let project = selectedProject else { return }
        isSaving = true
        errorMessage = nil
        do { try await operation() } catch { errorMessage = error.localizedDescription }
        isSaving = false
        // A transiently opened board is not on screen: don't reload it after every write.
        guard transientListing == nil else { return }
        await selectProject(project)
    }

    func location(of card: Card) -> (lane: Lane, path: String)? {
        guard let project = selectedProject, let board, let fileName = card.fileName else { return nil }
        guard let column = board.columns.first(where: { column in
            column.cards.contains { $0.fields.id == card.fields.id }
        }) else { return nil }
        return (column.lane, "\(project.folder)/\(column.lane.folder)/\(fileName)")
    }

    /// The id and file of a new card. A board whose cards are numbered (`PETS-012-…`), or
    /// that has no cards yet, gets the next number; a board of plainly named cards keeps
    /// naming them after their title.
    func newCardName(for title: String, lane: Lane, alsoTaken: [String] = [], prefix ownPrefix: String? = nil) -> (id: String, fileName: String) {
        let known = (board?.columns.flatMap { $0.cards.compactMap(\.fileName) } ?? [])
            + (transientListing?.files.values.joined().map { $0 } ?? []) + alsoTaken
        if let ownPrefix {
            let id = AgentBoard.nextID(prefix: ownPrefix, among: known)
            return (id, AgentBoard.fileName(id: id, title: title))
        }
        let numbered = known.contains { $0.range(of: #"^[A-Z][A-Z0-9]*-\d+"#, options: .regularExpression) != nil }
        if numbered || known.isEmpty,
           let prefix = AgentBoard.prefix(among: known, fallback: selectedProject?.name ?? "", ignoring: Set(products.compactMap(\.prefix))) {
            let id = AgentBoard.nextID(prefix: prefix, among: known)
            return (id, AgentBoard.fileName(id: id, title: title))
        }
        let id = uniqueID(for: title, lane: lane)
        return (id, "\(id).md")
    }

    private func uniqueID(for title: String, lane: Lane) -> String {
        let base = slug(title).isEmpty ? "task" : slug(title)
        let existing = Set((board?.columns.first { $0.lane.id == lane.id }?.cards ?? [])
            .compactMap { $0.fileName })
            .union(transientListing?.files[lane.id] ?? [])
        var name = "\(base).md"
        var n = 2
        while existing.contains(name) { name = "\(base)-\(n).md"; n += 1 }
        return String(name.dropLast(3))
    }

    private func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var result = String(mapped)
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private struct StoredConnection: Codable {
        let choice: ProviderChoice
        let serverURL: String?
        var login: String?
    }

    // MARK: - AI Quick Create

    private func loadAIConfig() {
        if let providerRaw = defaults.string(forKey: aiProviderKey),
           let provider = AIPontProvider(rawValue: providerRaw) {
            aiProvider = provider
        }
        if let model = defaults.string(forKey: aiModelKey), !model.isEmpty {
            aiModel = model
        }
        if let apiKey = defaults.string(forKey: aiAPIKeyKey) {
            aiAPIKey = apiKey
        }
    }

    public func saveAIConfig() {
        defaults.set(aiProvider.rawValue, forKey: aiProviderKey)
        defaults.set(aiModel, forKey: aiModelKey)
        defaults.set(aiAPIKey, forKey: aiAPIKeyKey)
    }

    /// Whether AI quick create can run: an API key, or the on-device model being usable.
    public var isAIConfigured: Bool { isUsable(aiProvider) }

    private func isUsable(_ provider: AIPontProvider) -> Bool {
        if provider == .onDevice { return OnDeviceAI.isAvailable }
        return provider == aiProvider && !aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The configured cloud provider, when it has a key. It can be sent images to look
    /// at; the on-device model cannot (it is text-only).
    public var imageAnalysisProvider: AIPontProvider? {
        aiProvider.needsAPIKey && isAIConfigured ? aiProvider : nil
    }

    /// Generate tickets from natural language input using AI.
    public func generateTicketsFromInput(
        _ input: String, using override: AIPontProvider? = nil, images: [AIImageAttachment] = [], single: Bool = false
    ) async {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let provider = override ?? aiProvider
        guard isUsable(provider) else {
            aiError = provider == .onDevice
                ? OnDeviceAI.unavailableReason
                : "Configure your AI API key in settings to use quick create."
            return
        }

        isGeneratingTickets = true
        aiError = nil
        generatedTickets = []

        let config = AIPontMagicConfiguration(
            provider: provider,
            apiKey: aiAPIKey,
            model: provider == aiProvider ? aiModel : provider.defaultModel
        )

        // Collect sample tickets to show the AI the style
        let samples = allCards.prefix(5).map { card in
            AITicketSample(
                title: card.fields.title,
                description: card.body.trimmingCharacters(in: .whitespacesAndNewlines),
                priority: card.fields.priority,
                type: card.fields.type
            )
        }

        let context = AITicketContext(
            projectName: selectedProject?.name ?? "Board",
            lanes: board?.config.lanes.map(\.name) ?? [],
            priorities: board?.config.priorities.map(\.id) ?? [],
            types: board?.config.types ?? [],
            epics: board?.config.epics.map(\.id) ?? [],
            existingTicketTitles: allCards.map(\.fields.title),
            sampleTickets: Array(samples)
        )

        do {
            if provider == .onDevice, single {
                // One ticket from the small model goes field by field; see `draftTicket`.
                generatedTickets = [try await OnDeviceAI.draftTicket(input: input, context: context)]
                isGeneratingTickets = false
                return
            }
            let service = AITicketService()
            generatedTickets = try await service.generateTickets(
                configuration: config,
                input: input,
                context: context,
                images: images
            )
            if generatedTickets.isEmpty {
                aiError = "Could not parse tickets from input. Try being more specific."
            }
        } catch {
            aiError = error.localizedDescription
        }

        isGeneratingTickets = false
    }

    /// The default lane for quick create (backlog or first "To do" lane).
    public var quickCreateDefaultLane: Lane? {
        guard let config = board?.config else { return nil }
        // Prefer backlog lane
        if let backlog = config.lanes.first(where: { $0.isBacklog && !$0.folder.isEmpty }) {
            return backlog
        }
        // Fall back to first non-empty lane (usually "To do")
        return config.lanes.first { !$0.folder.isEmpty }
    }

    /// Create a ticket from an AI-generated ticket into a specific lane.
    public func createFromGeneratedTicket(_ ticket: AIGeneratedTicket, in targetLane: Lane? = nil) async {
        guard let config = board?.config else { return }

        // Use target lane, or find lane from ticket, or use default
        let lane: Lane
        if let target = targetLane {
            lane = target
        } else if let laneName = ticket.lane,
           let matchedLane = config.lanes.first(where: { $0.name == laneName || $0.id == laneName }) {
            lane = matchedLane
        } else if let defaultLane = quickCreateDefaultLane {
            lane = defaultLane
        } else {
            return
        }

        await createTask(
            title: ticket.title,
            lane: lane,
            priority: ticket.priority,
            type: ticket.type,
            assignee: nil,
            epic: ticket.epic,
            body: ticket.description
        )

        // Remove from generated list
        generatedTickets.removeAll { $0.title == ticket.title }
    }

    /// Create all generated tickets at once into a specific lane.
    public func createAllGeneratedTickets(in targetLane: Lane? = nil) async {
        let tickets = generatedTickets
        for ticket in tickets {
            await createFromGeneratedTicket(ticket, in: targetLane)
        }
    }
}
