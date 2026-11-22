import Foundation
import GitKittieKit

// Labels, due dates and comments on a task, and the tasks of every board at once.

/// The open tasks of one board, for All Tasks.
public struct BoardTasks: Identifiable {
    public var repo: AddedRepo
    public var board: SelectedBoard
    public var config: EffectiveConfig
    /// Tasks in lanes that are neither the backlog nor the end of the line.
    public var open: [OpenTask]
    /// Why this board could not be read, when it could not.
    public var problem: String?
    public var id: String { "\(repo.id)|\(board.folder)" }

    public struct OpenTask: Identifiable, Sendable {
        public var card: Card
        public var lane: Lane
        public var id: String { card.id }
    }
}

extension AppModel {

    // MARK: Labels and due date

    /// Every label in use on the open board, for picking one.
    public var boardTags: [String] {
        Array(Set(allCards.flatMap(\.fields.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func setCardTags(_ card: Card, _ tags: [String]) async {
        var seen = Set<String>()
        let clean = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        await rewrite(card, message: "Label \(card.fields.id)") { CardText.update($0, set: ["updated_at": Review.timestamp(Date())], lists: ["tags": clean]) }
    }

    /// Set the day a task is due, or take it away with nil.
    public func setCardDue(_ card: Card, _ day: Date?) async {
        await rewrite(card, message: "Set due date of \(card.fields.id)") {
            CardText.update($0, set: ["due": day.map(CardDates.day), "updated_at": Review.timestamp(Date())])
        }
    }

    // MARK: Comments

    /// Add a comment to a task: one entry in its activity log, signed and dated.
    @discardableResult
    public func addComment(_ card: Card, _ text: String) async -> Bool {
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { return false }
        let author = reviewerID
        return await rewrite(card, message: "Comment on \(card.fields.id)") { original in
            let stamped = CardText.update(original, set: ["updated_at": Review.timestamp(Date())])
            return AgentCardText.appendActivity(stamped, entry: CardActivity.line(author: author, text: comment))
        }
    }

    /// Tick or untick the `index`th checkbox (`- [ ]`) in a task's text.
    public func toggleCheckbox(_ card: Card, index: Int) async {
        await rewrite(card, message: "Check off in \(card.fields.id)") { original in
            let (frontmatter, body) = BoardMarkdown.splitFrontmatter(original)
            guard let toggled = Self.togglingCheckbox(in: body, index: index) else { return original }
            let text = frontmatter.map { "---\n\($0)\n---\n\n" } ?? ""
            return CardText.update(text + toggled.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", set: ["updated_at": Review.timestamp(Date())])
        }
    }

    /// `text` with its `index`th checkbox flipped; nil when there is no such checkbox.
    nonisolated static func togglingCheckbox(in text: String, index: Int) -> String? {
        var lines = text.components(separatedBy: "\n")
        var seen = 0
        var fenced = false
        for position in lines.indices {
            let trimmed = lines[position].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced else { continue }
            for (open, done) in [("- [ ]", "- [x]"), ("* [ ]", "* [x]"), ("+ [ ]", "+ [x]")] {
                let isOpen = trimmed.hasPrefix(open)
                let isDone = trimmed.lowercased().hasPrefix(done)
                guard isOpen || isDone else { continue }
                if seen == index {
                    guard let range = lines[position].range(of: isOpen ? "[ ]" : (trimmed.hasPrefix(done) ? "[x]" : "[X]")) else { return nil }
                    lines[position].replaceSubrange(range, with: isOpen ? "[x]" : "[ ]")
                    return lines.joined(separator: "\n")
                }
                seen += 1
                break
            }
        }
        return nil
    }

    /// Read a task's file, change its text, write it back.
    @discardableResult
    private func rewrite(_ card: Card, message: String, _ change: @escaping (String) -> String) async -> Bool {
        guard let source, let location = location(of: card) else { return false }
        guard let original = try? await source.readText(location.path) else {
            errorMessage = "Could not read \(card.fields.id) to change it."
            return false
        }
        let updated = change(original)
        guard updated != original else { return true }
        await performWrite { try await source.write(path: location.path, text: updated, message: message) }
        return errorMessage == nil
    }

    // MARK: All tasks

    /// Tasks on every board in the sidebar, as counted when each was last listed.
    public var allTasksCount: Int {
        addedRepos.reduce(0) { sum, repo in sum + repo.boards.reduce(0) { $0 + (boardCount(repo, $1.folder) ?? 0) } }
    }

    /// Read the open tasks of every board in the sidebar. The board on screen and the
    /// boards that were on screen this session are not read again.
    public func loadAllTasks() async {
        guard !isLoadingAllTasks else { return }
        isLoadingAllTasks = true
        defer { isLoadingAllTasks = false }
        rememberOpenBoard()
        var known: [String: LoadedBoard] = [:]
        var wanted: [(repo: AddedRepo, board: SelectedBoard, source: any BoardWritable)] = []
        var problems: [String: String] = [:]
        for repo in addedRepos {
            for board in repo.boards {
                let key = "\(repo.id)|\(board.folder)"
                if let cached = boardCache[key] { known[key] = cached.board; continue }
                if let source = self.source(for: repo) { wanted.append((repo, board, source)) } else { problems[key] = "Not signed in for this repository." }
            }
        }
        await withTaskGroup(of: (String, Result<LoadedBoard, Error>).self) { group in
            for item in wanted {
                let key = "\(item.repo.id)|\(item.board.folder)"
                let source = item.source
                let folder = item.board.folder
                group.addTask {
                    do { return (key, .success(try await RemoteBoardStore.loadBoard(source: source, folder: folder, loadBacklog: false).board)) }
                    catch { return (key, .failure(error)) }
                }
            }
            for await (key, result) in group {
                switch result {
                case .success(let board): known[key] = board
                case .failure(let error): problems[key] = error.localizedDescription
                }
            }
        }
        allTasks = addedRepos.flatMap { repo in
            repo.boards.map { board -> BoardTasks in
                let key = "\(repo.id)|\(board.folder)"
                let loaded = known[key]
                let open = (loaded?.columns ?? [])
                    .filter { !$0.lane.isBacklog && $0.lane.terminal != true }
                    .flatMap { column in column.cards.map { BoardTasks.OpenTask(card: $0, lane: column.lane) } }
                return BoardTasks(repo: repo, board: board, config: loaded?.config ?? EffectiveConfig(), open: open, problem: problems[key])
            }
        }
    }

    /// Open a task picked in All Tasks: its board, with the task selected.
    public func openTask(_ task: BoardTasks.OpenTask, on tasks: BoardTasks) async {
        isShowingAllTasks = false
        isShowingReviews = false
        isShowingDocs = false
        if activeRepo?.id != tasks.repo.id || activeBoardFolder != tasks.board.folder {
            await openBoard(tasks.repo, folder: tasks.board.folder)
        }
        selectedCard = allCards.first { $0.id == task.card.id } ?? task.card
    }
}
