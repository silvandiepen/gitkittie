import Foundation
import GitKittieKit

// Choosing several files of one review request and acting on them at once (⌘A, ⌘/⇧-click
// on the Mac, Select on iPhone and iPad). What is chosen is a set of item ids; the request
// says which of them exist and whether a decision on them keeps a pick-one group's rule.

/// Approving would leave more than one option of a pick-one group approved.
public struct PickOneConflict: Equatable, Sendable {
    /// The group's name.
    public var group: String
    /// Its options that would be approved, in file order.
    public var items: [String]

    public var message: String {
        let names = items.count > 1 ? items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1] : items.joined()
        return "“\(group)” is pick one: approve only one of its options, not \(names)."
    }
}

public extension ReviewRequest {
    /// The items with these ids, in file order. Ids the request does not have are left out.
    func items(withIDs ids: some Collection<String>) -> [ReviewItem] {
        let wanted = Set(ids)
        return items.filter { wanted.contains($0.id) }
    }

    /// The ids of the items on show when `hidden` is hidden, in file order: what "select all" takes.
    func shownItemIDs(hiding hidden: Set<String> = []) -> [String] {
        items.map(\.id).filter { !hidden.contains($0) }
    }

    /// The first pick-one group that approving these items would leave with more than one
    /// approved option (counting the ones already approved), or `nil` when the rule holds.
    func pickOneConflict(approving ids: some Collection<String>) -> PickOneConflict? {
        let approving = Set(ids)
        for group in groups where group.pickOne {
            let approved = group.items.filter { approving.contains($0.id) || $0.status == .approved }
            if approved.count > 1, approved.contains(where: { approving.contains($0.id) }) {
                return PickOneConflict(group: group.name ?? "", items: approved.map(\.id))
            }
        }
        return nil
    }
}
