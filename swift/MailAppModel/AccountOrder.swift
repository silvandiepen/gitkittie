import Foundation
import MailCore

/// The order of the accounts in the sidebar and Settings (GKM-066), as the person arranged them.
/// Kept on this device in `preferences/accounts.json` beside the notification choices; accounts
/// not in it (new ones, or from another device) follow by name.
struct AccountOrder: Codable, Equatable {
    var order: [MailAccountID] = []

    /// The accounts in this order, the rest by name after them.
    func sorted(_ accounts: [MailAccount]) -> [MailAccount] {
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return accounts.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? Int.max
            let right = rank[rhs.element.id] ?? Int.max
            return (left, lhs.offset) < (right, rhs.offset)
        }.map(\.element)
    }

    static func url(deviceFolder: URL) -> URL {
        deviceFolder.appendingPathComponent("preferences", isDirectory: true).appendingPathComponent("accounts.json")
    }

    static func load(deviceFolder: URL) -> AccountOrder {
        let url = url(deviceFolder: deviceFolder)
        guard let data = try? Data(contentsOf: url) else { return AccountOrder() }
        // An unreadable file loses only the order: the accounts are listed by name.
        return (try? JSONDecoder().decode(AccountOrder.self, from: data)) ?? AccountOrder()
    }

    func save(deviceFolder: URL) throws {
        let url = Self.url(deviceFolder: deviceFolder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension AppModel {
    /// Moves accounts in the sidebar and Settings order, as a list's `onMove` gives them.
    func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int) async throws {
        guard let store = mailStore else { return }
        var ids = accounts.map(\.id)
        ids.moveElements(fromOffsets: source, toOffset: destination)
        try AccountOrder(order: ids).save(deviceFolder: store.locations.deviceFolder)
        try await reloadAfterAccountChange()
    }
}

extension Array {
    /// A list's move (SwiftUI's `onMove` offsets) without SwiftUI: the elements at `source`, in
    /// their order, end up before the element that was at `destination`.
    mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { self[$0] }
        let before = source.count(in: 0..<Swift.min(destination, count))
        for index in source.sorted(by: >) { remove(at: index) }
        insert(contentsOf: moving, at: Swift.max(0, Swift.min(destination - before, count)))
    }
}
