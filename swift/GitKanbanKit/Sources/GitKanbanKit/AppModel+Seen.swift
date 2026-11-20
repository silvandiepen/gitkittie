import Foundation
import GitKittieKit

// What changed since you last looked. Two levels:
//
// - Per card, exact: a card is *unseen* when its `updated_at` is newer than the last time
//   you opened it on this device, marked it read (`read_at`, in the repo), or first opened
//   its board. Kept on the device, so opening a card never commits anything.
// - Per board on the home screen, cheap: how many card files are new or sit in a different
//   lane than when you last opened the board, from directory listings alone.

/// How cards are ordered inside a lane or stage.
public enum CardSort: String, CaseIterable, Identifiable, Sendable {
    case board, unseenFirst, updated, priority

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .board: "Board Order"
        case .unseenFirst: "Unseen First"
        case .updated: "Last Updated"
        case .priority: "Priority"
        }
    }
}

/// A board on the home screen, from its directory listing.
public struct BoardSummary: Sendable, Equatable {
    public var total: Int
    /// Cards that are new or changed lane since the board was last opened.
    public var changed: Int
    /// Cards per lane, for lanes that are neither backlog nor terminal (the live work).
    public var active: [LaneCount]

    public struct LaneCount: Sendable, Equatable, Identifiable {
        public var name: String
        public var count: Int
        public var id: String { name }
    }
}

extension AppModel {
    private var seenCardsKey: String { "gitkanban.seenCards" }
    private var seenBaselinesKey: String { "gitkanban.seenBaselines" }
    private var boardSnapshotsKey: String { "gitkanban.boardSnapshots" }

    /// The storage key of the open board.
    var openBoardKey: String? {
        if isDemo { return "demo" }
        guard let repo = activeRepo, let folder = activeBoardFolder else { return nil }
        return "\(repo.id)|\(folder)"
    }

    func loadSeenState() {
        if let raw = defaults.string(forKey: "gitkanban.cardSort"), let sort = CardSort(rawValue: raw) { cardSort = sort }
        seenCards = Self.decodeDates(defaults.data(forKey: seenCardsKey))
        seenBaselines = Self.decodeDates(defaults.data(forKey: seenBaselinesKey))
        if let data = defaults.data(forKey: boardSnapshotsKey),
           let saved = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            boardSnapshots = saved
        }
    }

    private static func decodeDates(_ data: Data?) -> [String: Date] {
        guard let data, let raw = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return [:] }
        return raw.mapValues(Date.init(timeIntervalSince1970:))
    }

    private func persist(_ dates: [String: Date], key: String) {
        if let data = try? JSONEncoder().encode(dates.mapValues(\.timeIntervalSince1970)) { defaults.set(data, forKey: key) }
    }

    private func persistSnapshots() {
        if let data = try? JSONEncoder().encode(boardSnapshots) { defaults.set(data, forKey: boardSnapshotsKey) }
    }

    // MARK: Cards

    /// Whether a card was updated since you last looked at it.
    public func isUnseen(_ card: Card) -> Bool {
        guard let key = openBoardKey, let updated = BoardProgress.date(card.fields.updatedAt) else { return false }
        let seen = [seenBaselines[key], seenCards["\(key)|\(card.fields.id)"], BoardProgress.date(card.fields.readAt)]
            .compactMap { $0 }.max()
        guard let seen else { return true }
        return updated > seen
    }

    public var unseenCount: Int { allCards.filter(isUnseen).count }

    /// Record that the card was looked at now (on this device only).
    public func markSeen(_ card: Card) {
        guard let key = openBoardKey, !card.fields.id.isEmpty else { return }
        seenCards["\(key)|\(card.fields.id)"] = Date()
        persist(seenCards, key: seenCardsKey)
    }

    /// Everything on the open board counts as seen from now.
    public func markAllSeen() {
        guard let key = openBoardKey else { return }
        seenBaselines[key] = Date()
        seenCards = seenCards.filter { !$0.key.hasPrefix("\(key)|") }
        persist(seenBaselines, key: seenBaselinesKey)
        persist(seenCards, key: seenCardsKey)
    }

    /// Cards in the chosen order. `.board` keeps the order they came in.
    public func sorted(_ cards: [Card]) -> [Card] {
        func updated(_ card: Card) -> Date { BoardProgress.date(card.fields.updatedAt) ?? .distantPast }
        switch cardSort {
        case .board:
            return cards
        case .updated:
            return cards.sorted { updated($0) > updated($1) }
        case .unseenFirst:
            return cards.sorted { a, b in
                let ua = isUnseen(a), ub = isUnseen(b)
                return ua != ub ? ua : updated(a) > updated(b)
            }
        case .priority:
            let order = board?.config.priorities.map(\.id) ?? []
            func rank(_ card: Card) -> Int {
                card.fields.priority.flatMap { order.firstIndex(of: $0) } ?? Int.max
            }
            // Stable: equal priorities keep their board order.
            return cards.enumerated().sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        }
    }

    // MARK: Boards

    public func boardSummary(_ repo: AddedRepo, _ folder: String) -> BoardSummary? {
        boardSummaries["\(repo.id)|\(folder)"]
    }

    /// Summarize a board from its listing. The first time a board is ever summarized its
    /// current state becomes the reference, so nothing shows as changed until it does.
    public func loadBoardSummary(_ repo: AddedRepo, _ folder: String, force: Bool) async {
        let key = "\(repo.id)|\(folder)"
        guard force || boardSummaries[key] == nil, let source = source(for: repo),
              let listing = try? await RemoteBoardStore.listing(source: source, folder: folder) else { return }
        if boardSnapshots[key] == nil {
            boardSnapshots[key] = listing.locations
            persistSnapshots()
        }
        boardSummaries[key] = Self.summary(listing, since: boardSnapshots[key] ?? [:])
        rememberAppearance(name: listing.name, icon: listing.icon, color: listing.color, repoID: repo.id, folder: folder)
    }

    /// Refresh every added board's summary (pull to refresh on the home screen).
    public func refreshBoardSummaries() async {
        for repo in addedRepos {
            for board in repo.boards { await loadBoardSummary(repo, board.folder, force: true) }
        }
    }

    /// Opening a board is looking at it: its listing becomes the new reference, and the
    /// first open sets the baseline older updates are measured against.
    func boardWasOpened(_ repo: AddedRepo, folder: String) async {
        let key = "\(repo.id)|\(folder)"
        if seenBaselines[key] == nil {
            seenBaselines[key] = Date()
            persist(seenBaselines, key: seenBaselinesKey)
        }
        guard let source = source(for: repo),
              let listing = try? await RemoteBoardStore.listing(source: source, folder: folder) else { return }
        boardSnapshots[key] = listing.locations
        persistSnapshots()
        boardSummaries[key] = Self.summary(listing, since: listing.locations)
        rememberAppearance(name: listing.name, icon: listing.icon, color: listing.color, repoID: repo.id, folder: folder)
    }

    static func summary(_ listing: BoardListing, since snapshot: [String: String]) -> BoardSummary {
        let active = listing.lanes
            .filter { !$0.isBacklog && $0.terminal != true }
            .map { BoardSummary.LaneCount(name: $0.name, count: listing.count(in: $0)) }
            .filter { $0.count > 0 }
        return BoardSummary(total: listing.total, changed: listing.changes(since: snapshot), active: active)
    }
}
