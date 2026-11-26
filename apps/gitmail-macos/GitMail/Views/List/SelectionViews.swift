import MailCore
import MailStore
import SwiftUI

// "See All Mail from…" and a selection of many on the Mac (GKM-071, MAIL-098..100).

/// The row menu's first items: every message from the row's sender, across accounts and
/// folders; and blocking that sender in the row's account (GKM-072), Always Junk or Always
/// Trash, each shown as a preview first. A blocked sender offers to stop instead.
struct SeeAllMailFromButton: View {
    @Environment(AppModel.self) private var model
    let row: ListRow

    var body: some View {
        if let sender = row.latest.from, !sender.address.isEmpty {
            let name = SenderText.name(sender)
            Button("See All Mail from \(name)") {
                Task { await model.showAllMail(from: sender) }
            }
            if let rule = model.senders.blockingRule(for: sender.address, account: row.latest.account) {
                Button(SenderRuleText.unblockMenuTitle(rule, name: name)) {
                    Task { await model.senders.proposeRemoval(of: rule) }
                }
            } else {
                ForEach(SenderRuleText.blockActions, id: \.self) { action in
                    Button(SenderRuleText.blockMenuTitle(action, name: name)) {
                        Task { await model.senders.proposeBlock(action, address: sender, account: row.latest.account) }
                    }
                }
            }
            Divider()
        }
    }
}

/// The reader while several rows are selected: how many, and what can be done to all of them
/// in one step (one Undo).
struct SelectionSummaryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.browser
        let targets = browser.targets(actingOn: nil)
        let scope = browser.scope
        let actions = model.actions
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(browser.selectionTitle)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("selectionCount")
            HStack(spacing: 10) {
                Button("Archive", systemImage: "archivebox") {
                    Task { await actions.perform(.archive, targets: targets, in: scope) }
                }
                if actions.isTrash(scope) {
                    Button("Delete Permanently…", systemImage: "trash.slash") {
                        Task { await actions.requestDeletion(targets, in: scope) }
                    }
                } else {
                    Button("Move to Trash", systemImage: "trash") { Task { await actions.trash(targets, in: scope) } }
                }
                MoveToMenu(model: model, targets: targets)
                    .fixedSize()
            }
            HStack(spacing: 10) {
                Button("Mark as Read") { Task { await actions.perform(.markRead, targets: targets, in: scope) } }
                Button("Mark as Unread") { Task { await actions.perform(.markUnread, targets: targets, in: scope) } }
                Button("Flag") { Task { await actions.perform(.flag, targets: targets, in: scope) } }
                Button("Unflag") { Task { await actions.perform(.unflag, targets: targets, in: scope) } }
            }
            Button("Deselect All") { browser.clearMarks() }
                .buttonStyle(.link)
        }
        .controlSize(.large)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
