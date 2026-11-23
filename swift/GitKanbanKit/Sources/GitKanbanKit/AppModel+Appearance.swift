import Foundation
import GitKittieKit

// A board's own settings: its display name, icon and colour. They live in the board's
// README (`project:`, `icon:`, `color:`), so they travel with the repo to every device; the
// saved board list keeps the last values read, so the sidebar shows them without opening
// each board.

extension AppModel {
    /// Keep the saved board equal to what its README says. A README without a name leaves
    /// the saved name alone (it is the folder's name then).
    func rememberAppearance(name: String?, icon: String?, color: String?, repoID: String, folder: String) {
        guard let repoIndex = addedRepos.firstIndex(where: { $0.id == repoID }),
              let boardIndex = addedRepos[repoIndex].boards.firstIndex(where: { $0.folder == folder }) else { return }
        let board = addedRepos[repoIndex].boards[boardIndex]
        let name = name ?? board.name
        guard board.icon != icon || board.color != color || board.name != name else { return }
        addedRepos[repoIndex].boards[boardIndex].name = name
        addedRepos[repoIndex].boards[boardIndex].icon = icon
        addedRepos[repoIndex].boards[boardIndex].color = color
        persistAddedRepos()
    }

    /// Write a board's display name, icon and colour into its README (`nil` removes the
    /// icon or colour). Every other line of the README is kept as it is.
    public func saveBoardSettings(_ board: SelectedBoard, in repo: AddedRepo, name rawName: String, icon: String?, color: String?) async {
        guard let source = source(for: repo) else { return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? board.name : trimmed
        let path = board.folder.isEmpty ? "README.md" : "\(board.folder)/README.md"
        errorMessage = nil
        // Shown at once; the write goes out through the outbox like any other change.
        rememberAppearance(name: name, icon: icon, color: color, repoID: repo.id, folder: board.folder)
        do {
            let existing: String
            do {
                existing = try await source.readText(path)
            } catch {
                // Only a board that really has no README gets a new one; a failed read must
                // not turn into overwriting the one that is there.
                let names = try await source.list(board.folder).map(\.name)
                guard !names.contains("README.md") else { throw error }
                existing = "---\nconfig: project\n---\n\n# \(name)\n"
            }
            var changes: [String: String?] = ["icon": icon, "color": color]
            // The name is only written when it changed, so a README that never named its
            // board is not given a `project:` line by picking a colour.
            if name != board.name { changes["project"] = name }
            let updated = CardText.update(existing, set: changes)
            guard updated != existing else { return }
            try await source.write(path: path, text: updated, message: "Update \(name) board settings")
            if activeRepo?.id == repo.id, activeBoardFolder == board.folder, selectedProject != nil {
                selectedProject?.name = name
                selectedProject?.config.project = name
                selectedProject?.config.icon = icon
                selectedProject?.config.color = color
            }
        } catch {
            errorMessage = "The board settings were not saved: \(error.localizedDescription)"
        }
    }
}

// A folder that was added as a board but holds no board: usually the project's own folder
// (`Arvik`) picked where its board (`Tasks/Arvik`) was meant.

extension AppModel {
    /// Whether the open board loaded but has neither cards nor any lane folder with cards.
    public var openBoardIsEmpty: Bool {
        guard let board, !isLoadingBoard else { return false }
        return board.columns.allSatisfy(\.cards.isEmpty) && board.uncategorised.isEmpty
    }

    /// A folder of the same name next to the repo's other boards, when the open one is not
    /// there itself: `Tasks/Arvik` for an open `Arvik` when the other boards are `Tasks/…`.
    public func betterFolderForOpenBoard() async -> String? {
        guard let repo = activeRepo, let folder = activeBoardFolder, !folder.isEmpty else { return nil }
        let name = folder.split(separator: "/").last.map(String.init) ?? folder
        let parents = Set(repo.boards.filter { $0.folder != folder }.compactMap { board -> String? in
            board.folder.lastIndex(of: "/").map { String(board.folder[..<$0]) }
        })
        for parent in parents.sorted() where "\(parent)/\(name)" != folder {
            if await listFolders(in: repo, at: parent).contains(where: { $0.name == name }) { return "\(parent)/\(name)" }
        }
        return nil
    }

    /// Point the open board's sidebar entry at another folder and open that.
    public func moveOpenBoard(to folder: String) async {
        guard let repo = activeRepo, let old = activeBoardFolder,
              let repoIndex = addedRepos.firstIndex(where: { $0.id == repo.id }) else { return }
        var boards = addedRepos[repoIndex].boards.filter { $0.folder != old && $0.folder != folder }
        boards.append(SelectedBoard(folder: folder, name: folder.split(separator: "/").last.map(String.init) ?? folder))
        setBoards(boards, for: repo.id)
        await openBoard(addedRepos[repoIndex], folder: folder)
    }
}
