import MailCore
import MailStore
import SwiftUI

/// In the reader's "Why?": which of your sender rules decided this message, why it won, and
/// which others also matched (GKM-019). Opens the sender in the Senders view.
struct SenderRuleReason: View {
    @Environment(AppModel.self) private var model
    let message: MailMessageID
    @State private var explanation: SenderRuleExplanation?

    var body: some View {
        Group {
            if let explanation {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your rule “\(SenderRuleText.title(explanation.winner.action))” for \(explanation.winner.scope.name) \(SenderRuleText.effect(explanation.effect)). It’s rule \(explanation.position) in your order and the first that matches.")
                    if !explanation.alsoMatched.isEmpty {
                        Text("Also matched, but later in your order: " + explanation.alsoMatched.map { "“\(SenderRuleText.title($0.action))” for \($0.scope.name)" }.joined(separator: ", ") + ".")
                            .foregroundStyle(.secondary)
                    }
                    Button("Show in Senders") { Task { await show(explanation.winner) } }
                        .buttonStyle(.link)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: message) { explanation = await model.senderRuleExplanation(for: message) }
    }

    private func show(_ rule: SenderRule) async {
        await model.select(.senders)
        await model.senders.refresh()
        model.senders.selectedID = model.senders.senders.first { $0.account == rule.account && $0.scope == rule.scope }?.id
    }
}
