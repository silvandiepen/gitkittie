import Foundation
import MailClassifier
import MailCore
import MailStore

// The Senders view's intents that reach beyond it (GKM-019, GKM-020).

extension AppModel {
    /// "Report as Junk", offered instead of unsubscribe for suspicious mail: this message goes to
    /// Quarantine here, and, when the account has a junk folder, is moved there at the provider
    /// (through the action journal, with Undo). Over IMAP that move is how a provider learns it
    /// (ProviderAccess.md); no other report is sent.
    func reportJunk(_ id: MailMessageID) async {
        guard let store = mailStore else { return }
        do {
            try await store.correct(id, risk: .spam)
            if let summary = try await store.summary(of: id),
               let junk = sync.folders[summary.account]?.first(where: { $0.role == "junk" })?.name {
                await actions.perform(.move(to: junk, account: summary.account), messages: [summary], in: .allMail)
            }
        } catch {
            actionError = String(describing: error)
        }
        await browser.refreshAfterClassificationChange()
        await attention.refresh(accounts: accounts, arrivals: .leave)
        await senders.refresh()
    }
}

extension AppModel {
    /// Which sender rule decided this message, for the reader's "Why?".
    func senderRuleExplanation(for id: MailMessageID) async -> SenderRuleExplanation? {
        guard let store = mailStore else { return nil }
        do {
            return try await store.explainSenderRule(for: id)
        } catch {
            actionError = String(describing: error)
            return nil
        }
    }
}
