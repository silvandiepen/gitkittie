import Foundation

// Several conversations at once (GKM-022): ⌘-click adds or removes one row, ⇧-click takes the
// rows between the selected one and the click. What a drag or a menu then acts on is every
// marked row, or the one row it started from when that row is not marked.
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

    /// The conversations an action on `rowID` covers: all marked rows when it is one of them,
    /// otherwise that row alone. With no row, the marked rows, or else the selected one.
    func threadIDs(actingOn rowID: String?) -> [String] {
        let ids: [String]
        if let rowID, !markedRowIDs.contains(rowID) {
            ids = [rowID]
        } else if !markedRowIDs.isEmpty {
            ids = rows.map(\.id).filter { markedRowIDs.contains($0) }
        } else {
            ids = [rowID ?? selectedRowID].compactMap { $0 }
        }
        var seen = Set<String>()
        return ids.compactMap { id in rows.first { $0.id == id }?.threadID }.filter { seen.insert($0).inserted }
    }
}
