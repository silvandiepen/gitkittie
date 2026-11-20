import Foundation
import GitKittieKit

// Moving a card to another project in the same repo or folder: the card file goes to the
// other project's lane folder, its `project` (and `status`) fields follow, and its
// attachments folder moves with it.

/// Where a card would go, worked out before anything is written.
public struct ProjectMovePlan: Identifiable {
    public var id: String { "\(cardID)->\(target.folder)" }
    public let cardID: String
    public let cardTitle: String
    let sourcePath: String
    let sourceFolder: String
    let fileName: String
    public let target: SelectedBoard
    let targetProjectName: String
    /// The lane it lands in: the one with the same name, else the target's first lane.
    public let lane: Lane
    let takenFileNames: Set<String>
    /// The next free id in the target project, offered when the target numbers its cards
    /// and this card is not numbered that way: another project's prefix (`ARVIK-075` going
    /// to `GITKIT-…`), or no number at all (a slug id such as `review-doesn-t-work`).
    /// `nil` when there is nothing to ask.
    public let suggestedID: String?
}

extension AppModel {
    /// The other boards of the open repo or folder: where a card can be moved to.
    public var otherProjects: [SelectedBoard] {
        guard let repo = activeRepo, let current = activeBoardFolder else { return [] }
        return (addedRepos.first { $0.id == repo.id } ?? repo).boards.filter { $0.folder != current }
    }

    /// Work out the move. When the id question applies it is put to the user
    /// (`pendingProjectMove`); otherwise the card moves straight away.
    public func startMove(_ card: Card, to board: SelectedBoard) async {
        guard let plan = await planMove(card, to: board) else { return }
        if plan.suggestedID != nil {
            pendingProjectMove = plan
        } else {
            await finishMove(plan, renumber: false)
        }
    }

    func planMove(_ card: Card, to board: SelectedBoard) async -> ProjectMovePlan? {
        guard let source, let project = selectedProject, let location = location(of: card),
              let fileName = card.fileName else { return nil }
        errorMessage = nil
        do {
            let shell = try await RemoteBoardStore.loadBoardShell(source: source, folder: board.folder)
            let lanes = shell.board.config.lanes.filter { !$0.folder.isEmpty }
            let sameName = lanes.first { $0.name.caseInsensitiveCompare(location.lane.name) == .orderedSame || $0.id == location.lane.id }
            guard let lane = sameName ?? lanes.first(where: { !$0.isBacklog }) ?? lanes.first else {
                errorMessage = "\(board.name) has no lanes to move the task to."
                return nil
            }
            let allNames = shell.listing.files.values.flatMap { $0 }
            return ProjectMovePlan(
                cardID: card.fields.id, cardTitle: card.fields.title.isEmpty ? card.fields.id : card.fields.title,
                sourcePath: location.path, sourceFolder: project.folder, fileName: fileName,
                target: board, targetProjectName: shell.project.name, lane: lane,
                takenFileNames: Set(shell.listing.files[lane.id] ?? []),
                suggestedID: Self.nextID(for: card.fields.id, among: allNames))
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// `PREFIX-123` split into its parts; `nil` for ids that are not numbered that way.
    static func numbered(_ id: String) -> (prefix: String, number: Int, width: Int)? {
        guard let dash = id.lastIndex(of: "-") else { return nil }
        let prefix = String(id[..<dash]), digits = String(id[id.index(after: dash)...])
        guard !prefix.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber),
              prefix.allSatisfy({ $0.isLetter || $0.isNumber }), prefix.first?.isLetter == true,
              let number = Int(digits) else { return nil }
        return (prefix, number, digits.count)
    }

    /// The next id in the prefix the target project's cards mostly use, when that differs
    /// from the card's own. File names look like `PREFIX-123-some-title.md`.
    static func nextID(for cardID: String, among fileNames: [String]) -> String? {
        let own = numbered(cardID)
        var highest: [String: (number: Int, width: Int, count: Int)] = [:]
        for name in fileNames {
            let parts = name.replacingOccurrences(of: ".md", with: "").split(separator: "-", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let found = numbered("\(parts[0])-\(parts[1])") else { continue }
            let seen = highest[found.prefix]
            highest[found.prefix] = (max(seen?.number ?? 0, found.number), max(seen?.width ?? 0, found.width), (seen?.count ?? 0) + 1)
        }
        guard let (prefix, top) = highest.max(by: { $0.value.count < $1.value.count }),
              own.map({ prefix.caseInsensitiveCompare($0.prefix) != .orderedSame }) ?? true else { return nil }
        let digits = String(top.number + 1)
        return "\(prefix)-\(String(repeating: "0", count: max(0, top.width - digits.count)))\(digits)"
    }

    /// The file name under a new id: the id part is swapped and the slug kept. A card whose
    /// id was its slug (`review-doesn-t-work.md`) keeps that slug behind the new id.
    static func fileName(_ fileName: String, from oldID: String, to newID: String) -> String {
        let stem = fileName.hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
        if numbered(oldID) != nil, stem.hasPrefix(oldID) { return newID + stem.dropFirst(oldID.count) + ".md" }
        return "\(newID)-\(stem).md"
    }

    /// Carry the move out. With `renumber` the card takes `plan.suggestedID`.
    public func finishMove(_ plan: ProjectMovePlan, renumber: Bool) async {
        pendingProjectMove = nil
        guard let source else { return }
        let newID = renumber ? (plan.suggestedID ?? plan.cardID) : plan.cardID
        var fileName = plan.fileName
        if newID != plan.cardID { fileName = Self.fileName(plan.fileName, from: plan.cardID, to: newID) }
        var stem = String(fileName.dropLast(3)), copy = 2
        while plan.takenFileNames.contains("\(stem).md") {
            stem = String(fileName.dropLast(3)) + "-\(copy)"
            copy += 1
        }
        let targetPath = "\(plan.target.folder)/\(plan.lane.folder)/\(stem).md"
        let oldAttachments = "\(plan.sourceFolder)/attachments/\(plan.cardID)"
        let newAttachments = "\(plan.target.folder)/attachments/\(newID)"

        await performWrite {
            let original = try await source.readText(plan.sourcePath)
            var fields: [String: String?] = ["project": plan.targetProjectName, "status": plan.lane.status]
            if newID != plan.cardID { fields["id"] = newID }
            try await source.write(path: targetPath, text: CardText.update(original, set: fields),
                                   message: "Move \(plan.cardID) to \(plan.targetProjectName)")
            // Attachments are copied before anything is removed, so an interrupted move
            // leaves a duplicate rather than a loss.
            let attachments = ((try? await source.list(oldAttachments)) ?? []).filter { $0.kind == .file }
            for file in attachments {
                let data = try await source.readData(file.path)
                try await source.writeData(path: "\(newAttachments)/\(file.name)", data: data,
                                           message: "Move \(file.name) with \(newID)")
            }
            for file in attachments {
                try await source.delete(path: file.path, message: "Move \(file.name) with \(newID)")
            }
            try await source.delete(path: plan.sourcePath, message: "Move \(plan.cardID) to \(plan.targetProjectName)")
        }
        if errorMessage == nil, let repo = activeRepo { boardSummaries["\(repo.id)|\(plan.target.folder)"] = nil }
        await loadAttachmentIndex()
    }
}
