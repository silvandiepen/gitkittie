import Foundation
import MailStore

// The cleanup dashboard's sender and list suggestions (GKM-021) go through the Senders view's
// rules (GKM-019, MAIL-054): its dry-run preview, its apply and its Undo. The dashboard makes no
// rules of its own.

extension AppModel {
    /// The Senders view's entry for a cleanup group of one sender or list.
    func sender(for group: CleanupGroupID) -> SenderSummary? {
        senders.senders.first { sender in
            guard sender.account == group.account else { return false }
            switch group.kind {
            case .list(let list): return sender.scope.listID == list
            case .sender(let address): return sender.scope.address == address
            default: return false
            }
        }
    }

    /// "Mute", "Always list under …": opens the sender in the Senders view with the rule's
    /// preview. Nothing changes until you apply it there.
    func proposeSenderRule(_ action: SenderRuleAction, for group: CleanupGroupID) async {
        await senders.refresh()
        guard let sender = sender(for: group) else {
            cleanup.notice = "This sender isn’t in the Senders view yet."
            return
        }
        await select(.senders)
        senders.selectedID = sender.id
        await senders.propose(action, for: sender)
    }
}
