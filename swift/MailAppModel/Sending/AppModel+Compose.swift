import Foundation
import MailCompose
import MailCore

/// New Message, Reply, Reply All and Forward: each makes a saved draft and returns its id for
/// a compose window to open.
extension AppModel {
    enum ComposeAction { case reply, replyAll, forward }

    /// True when there is an open message to answer.
    var canAnswer: Bool { openMessage != nil && sending != nil }

    func composeNew() async -> DraftID? {
        guard let sending else { return nil }
        let identities = await sending.identities(accounts: accounts)
        let preferred = selectedAccount.flatMap { account in identities.first { $0.account == account.id } } ?? identities.first
        do {
            return try await sending.newDraft(from: preferred)
        } catch {
            actionError = "A new message couldn’t be started: \(error)"
            return nil
        }
    }

    func compose(_ action: ComposeAction) async -> DraftID? {
        guard let sending, let message = openMessage else { return nil }
        let id = message.front.id
        let account = message.front.account
        do {
            // A partial message (GKM-036): a reply needs its header and text, which it has; a
            // forward carries the attachments, so they are downloaded first (offline: it says so).
            if action == .forward, try await mailStore?.isPartial(id) == true {
                await completePartialMessages([(id, account)])
            }
            let original = action == .forward ? try await originalData(of: id) : try await replySource(of: id)
            let identities = await sending.identities(accounts: accounts)
            switch action {
            case .reply:
                return try await sending.replyDraft(to: original, source: id, account: account, identities: identities, all: false)
            case .replyAll:
                return try await sending.replyDraft(to: original, source: id, account: account, identities: identities, all: true)
            case .forward:
                return try await sending.forwardDraft(of: original, source: id, account: account, identities: identities)
            }
        } catch {
            actionError = "The reply couldn’t be started: \(error)"
            return nil
        }
    }
}
