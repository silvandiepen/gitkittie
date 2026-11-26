import Foundation
import MailCore
import MailStore

// Several conversations at once (GKM-022, GKM-071): ⌘-click adds or removes one row, ⇧-click
// takes the rows between the selected one and the click, ⌘A (or Select All on iOS) takes every
// row of the view — loaded or not, by id from the store, so thousands load no rows. What a drag
// or a menu then acts on is every marked row, or the one row it started from when that row is
// not marked. The marks belong to one view: changing the view, the search or a chip ends them.
extension MailBrowser {
    /// ⌘-click: adds or removes a row. The selected row joins the marks when marking starts.
    func toggleMark(_ rowID: String) {
        var marks = markedRowIDs
        if marks.isEmpty, let selected = selectedRowID, selected != rowID { marks.insert(selected) }
        if marks.contains(rowID) { marks.remove(rowID) } else { marks.insert(rowID) }
        markedRowIDs = marks
    }

    /// ⇧-click: every row from the selected one (or the first marked) to this one.
    func extendMark(to rowID: String) {
        guard let end = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let anchorID = selectedRowID ?? rows.first { markedRowIDs.contains($0.id) }?.id
        let start = anchorID.flatMap { id in rows.firstIndex { $0.id == id } } ?? end
        markedRowIDs = Set(rows[min(start, end)...max(start, end)].map(\.id))
    }

    func clearMarks() {
        if !markedRowIDs.isEmpty { markedRowIDs = [] }
    }

    func isMarked(_ rowID: String) -> Bool { markedRowIDs.contains(rowID) }

    /// ⌘A: every row the view has, not only the loaded page. The ids are read once, now: mail
    /// that arrives afterwards is not part of it, because you never saw it (as in Clean Up,
    /// MAIL-060). A view that changed while the ids were read keeps its own marks.
    func selectAll() async {
        guard let store else { return }
        let identity = listIdentity
        do {
            let ids = try await viewRowIDs(from: store)
            guard identity == listIdentity else { return }
            markedRowIDs = Set(ids)
        } catch {
            actionError = String(describing: error)
        }
    }

    /// How many rows an action without a row would act on: the marks, or the selected row.
    var selectionCount: Int {
        markedRowIDs.isEmpty ? (selectedRowID == nil ? 0 : 1) : markedRowIDs.count
    }

    /// More than one row is selected: the reader shows the count and the actions instead.
    var selectsMany: Bool { markedRowIDs.count > 1 }

    /// "312 conversations selected", or messages while the list shows single messages.
    var selectionTitle: String { SelectionText.selected(selectionCount, messages: isSearching) }

    /// The conversations an action on `rowID` covers: all marked rows when it is one of them,
    /// otherwise that row alone. With no row, the marked rows, or else the selected one. For
    /// spaces, which hold conversations; actions use ``targets(actingOn:)``.
    func threadIDs(actingOn rowID: String?) -> [String] {
        var seen = Set<String>()
        return rowIDs(actingOn: rowID).compactMap { id in rows.first { $0.id == id }?.threadID }.filter { seen.insert($0).inserted }
    }

    /// What an action on `rowID` covers, as ``threadIDs(actingOn:)`` picks the rows: a
    /// conversation row is the whole conversation; a message row (while searching, and in
    /// "See All Mail from…") is that message alone, so deleting everything from a sender never
    /// takes your replies or anyone else's messages in those conversations (MAIL-098). Rows
    /// that are marked but not loaded count too: they come from the ids.
    func targets(actingOn rowID: String?) -> ActionTargets {
        var targets = ActionTargets()
        for id in rowIDs(actingOn: rowID) {
            if id.hasPrefix("t:") {
                targets.threads.append(String(id.dropFirst(2)))
            } else if id.hasPrefix("m:"), let message = MailMessageID(String(id.dropFirst(2))) {
                targets.messages.append(message)
            }
        }
        return targets
    }

    /// The loaded rows among `targets`, for what a menu offers (Mark as Read or Unread).
    func loadedRows(of targets: ActionTargets) -> [ListRow] {
        let ids = Set(targets.threads.map { "t:" + $0 } + targets.messages.map(ListRow.id(of:)))
        return rows.filter { ids.contains($0.id) }
    }

    /// The row ids an action covers, the loaded ones in the list's order, then the rest.
    private func rowIDs(actingOn rowID: String?) -> [String] {
        if let rowID, !markedRowIDs.contains(rowID) { return [rowID] }
        guard !markedRowIDs.isEmpty else { return [rowID ?? selectedRowID].compactMap { $0 } }
        let loaded = rows.map(\.id).filter { markedRowIDs.contains($0) }
        let rest = markedRowIDs.subtracting(loaded).sorted()
        return loaded + rest
    }

}

/// What an action covers: whole conversations, single messages, or both.
struct ActionTargets: Equatable {
    var threads: [String] = []
    var messages: [MailMessageID] = []

    var count: Int { threads.count + messages.count }
    var isEmpty: Bool { threads.isEmpty && messages.isEmpty }
    /// True when it is messages, not conversations, for the words.
    var isMessages: Bool { threads.isEmpty && !messages.isEmpty }
}

/// How a sender is named in "See All Mail from…" and its chip.
enum SenderText {
    static func name(_ sender: MailAddress) -> String {
        let name = sender.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? sender.address : name
    }
}

/// The words for a selection of many.
enum SelectionText {
    static func selected(_ count: Int, messages: Bool) -> String {
        "\(things(count, messages: messages)) selected"
    }

    /// "1 conversation", "312 messages".
    static func things(_ count: Int, messages: Bool) -> String {
        let noun = messages ? (count == 1 ? "message" : "messages") : (count == 1 ? "conversation" : "conversations")
        return "\(count.formatted()) \(noun)"
    }

    /// The question before a large Move to Trash.
    static func trashQuestion(_ targets: ActionTargets) -> String {
        "Move \(things(targets.count, messages: targets.isMessages)) to Trash?"
    }
}
