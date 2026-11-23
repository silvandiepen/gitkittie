import Foundation
import GitKittieKit

// New boards in a repository that is already added. A board made somewhere else (another
// device, an agent) is a new folder next to the boards you have; the app notices it on
// its regular checks and asks once whether to add it.

/// A board folder that appeared next to the boards of an added repository.
public struct BoardSuggestion: Identifiable, Hashable, Sendable {
    public let repoID: String
    public let repoName: String
    public let folder: String
    public let name: String
    public var id: String { "\(repoID)|\(folder)" }
}

extension AppModel {
    private static let knownFoldersKey = "gitkanban.newBoards.knownFolders"
    private static let announcedKey = "gitkanban.newBoards.announced"

    /// The folders that hold a repository's boards: the parent of each selected board.
    static func boardParents(of boards: [SelectedBoard]) -> Set<String> {
        Set(boards.filter { !$0.folder.isEmpty }.map { board in
            board.folder.split(separator: "/").dropLast().joined(separator: "/")
        })
    }

    /// The folders that are new: there now, not there at the last look, and not a board
    /// already. `known == nil` is the first look, which only sets what "there" means.
    static func newFolders(now: [String], known: [String]?, selected: [String]) -> [String] {
        guard let known else { return [] }
        let old = Set(known), have = Set(selected)
        return now.filter { !old.contains($0) && !have.contains($0) }
    }

    /// Look for new boards next to the ones in the sidebar, and say so once for each.
    public func refreshBoardSuggestions() async {
        var known = (defaults.dictionary(forKey: Self.knownFoldersKey) as? [String: [String]]) ?? [:]
        var announced = Set(defaults.stringArray(forKey: Self.announcedKey) ?? [])
        var found: [BoardSuggestion] = []
        for repo in addedRepos where !repo.boards.isEmpty {
            guard let source = source(for: repo) else { continue }
            for parent in Self.boardParents(of: repo.boards) {
                let key = "\(repo.id)|\(parent)"
                // A failed listing is not "no folders": leave what is known alone.
                guard let entries = try? await source.list(parent) else { continue }
                let folders = entries.filter { $0.kind == .directory && !$0.name.hasPrefix(".") }.map(\.path)
                let fresh = Self.newFolders(now: folders, known: known[key], selected: repo.boards.map(\.folder))
                if known[key] == nil { known[key] = folders; continue }
                for folder in fresh {
                    // A board has lanes: at least one of its lane folders is there.
                    let (name, config) = await RemoteBoardStore.loadEffectiveConfig(source: source, folder: folder)
                    let inside = Set(((try? await source.list(folder)) ?? []).filter { $0.kind == .directory }.map(\.name))
                    guard config.lanes.contains(where: { inside.contains($0.folder) }) else {
                        known[key, default: []].append(folder)   // not a board: never ask about it
                        continue
                    }
                    found.append(BoardSuggestion(repoID: repo.id, repoName: repo.name, folder: folder, name: name))
                }
            }
        }
        defaults.set(known, forKey: Self.knownFoldersKey)
        boardSuggestions = found
        for suggestion in found where !announced.contains(suggestion.id) {
            announced.insert(suggestion.id)
            await postNewBoard(suggestion)
        }
        defaults.set(Array(announced), forKey: Self.announcedKey)
    }

    /// Yes: the board goes into the sidebar.
    public func addSuggestedBoard(_ suggestion: BoardSuggestion) {
        if let repo = addedRepos.first(where: { $0.id == suggestion.repoID }),
           !repo.boards.contains(where: { $0.folder == suggestion.folder }) {
            setBoards(repo.boards + [SelectedBoard(folder: suggestion.folder, name: suggestion.name)], for: repo.id)
        }
        settle(suggestion)
    }

    /// No: it is not asked about again. The board can still be added from Browse Boards.
    public func dismissBoardSuggestion(_ suggestion: BoardSuggestion) { settle(suggestion) }

    private func settle(_ suggestion: BoardSuggestion) {
        var known = (defaults.dictionary(forKey: Self.knownFoldersKey) as? [String: [String]]) ?? [:]
        let parent = suggestion.folder.split(separator: "/").dropLast().joined(separator: "/")
        known["\(suggestion.repoID)|\(parent)", default: []].append(suggestion.folder)
        defaults.set(known, forKey: Self.knownFoldersKey)
        boardSuggestions.removeAll { $0.id == suggestion.id }
    }
}
