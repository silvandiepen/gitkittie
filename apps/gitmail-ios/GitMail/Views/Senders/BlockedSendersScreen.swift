import MailStore
import SwiftUI

/// Your Always Junk and Always Trash rules (GKM-072), in Settings: who is blocked, where their
/// mail goes, and Remove. Removing shows its preview first and says that mail already moved
/// stays where it is.
struct BlockedSendersScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var senders = model.senders
        List {
            if senders.blockingRules.isEmpty {
                Text("No one is blocked. To block a sender, touch and hold a message from them and choose Always Junk or Always Trash.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(senders.blockingRules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.scope.name)
                                Text(SenderRuleText.title(rule.action) + (rule.isEnabled ? "" : " · Off"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { Task { await senders.proposeRemoval(of: rule) } }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove the rule for \(rule.scope.name)")
                        }
                    }
                } footer: {
                    Text("New mail from these senders moves to Junk or Trash at your mail provider after each check for mail. Flagged mail and mail in a space stay where they are. Removing a rule doesn’t move mail back.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle("Blocked Senders")
        .sheet(item: $senders.pending) { _ in RulePreviewScreen() }
        .task { await senders.refresh() }
    }
}
