import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// "Why is this in Promotions?" (GKM-017): where the message is and why, in one quiet line that
/// opens to the reasons; corrections for this message; and, only after you corrected it, the
/// offer to make a rule for its sender or list. Nothing here touches the provider.
struct ClassificationPanel: View {
    @Environment(AppModel.self) private var model
    let message: ThreadMessage
    @State private var showsReasons = false
    @State private var rule: ClassificationRule?
    @State private var correction: ClassificationCorrection?

    var body: some View {
        if let verdict = message.verdict {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: verdict.home.systemImage)
                        .foregroundStyle(verdict.home == .quarantine ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                    Text(VerdictText.summary(verdict)).foregroundStyle(.secondary)
                    Button(showsReasons ? "Hide" : "Why?") { withAnimation(.easeOut(duration: 0.15)) { showsReasons.toggle() } }
                        .buttonStyle(.link)
                        .accessibilityHint("Shows why this message is here")
                    Spacer(minLength: 8)
                    actions(verdict)
                }
                .font(.callout)
                if verdict.classification.risk == .suspicious {
                    Notice(systemImage: "exclamationmark.triangle", tint: .orange,
                           text: "Something about this message looks off. It stays in view; check it before acting on it.")
                }
                if showsReasons { reasons(verdict) }
                ruleOffer(verdict)
            }
            .padding(.top, 10)
            .task(id: verdict) {
                rule = await model.rule(for: verdict)
                correction = await model.correction(of: message.id)
            }
        }
    }

    // MARK: Reasons

    private func reasons(_ verdict: StoredVerdict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(VerdictText.reasons(verdict), id: \.self) { line in
                Label(line, systemImage: "circle.fill")
                    .labelStyle(BulletLabelStyle())
            }
            Text("Sorted on this Mac by rule set \(verdict.classification.ruleSetVersion). Nothing was changed at your mail provider.")
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.leading, 26)
    }

    // MARK: Corrections

    private func actions(_ verdict: StoredVerdict) -> some View {
        Menu {
            Section("Move This Message To") {
                ForEach(MailPurpose.correctable, id: \.self) { purpose in
                    Button(purpose.destinationTitle) { Task { await model.move(message.id, to: purpose) } }
                        .disabled(purpose == verdict.classification.purpose)
                }
            }
            Divider()
            switch verdict.classification.risk {
            case .phishing: Button("Not Phishing") { Task { await model.clearRisk(message.id) } }
            case .spam: Button("Not Junk") { Task { await model.clearRisk(message.id) } }
            case .suspicious, .none: Button("Report as Phishing") { Task { await model.markPhishing(message.id) } }
            }
            if verdict.classification.reasons.contains(.userOverride) {
                Divider()
                Button("Undo My Correction") { Task { await model.undoCorrection(message.id) } }
            }
            if let rule {
                Button("Remove My Rule for This \(rule.scopeNoun)") { Task { await model.removeRule(id: rule.id) } }
            }
            if let list = verdict.listID {
                Divider()
                Picker("Notifications for This List", selection: listLevel(list, account: verdict.account)) {
                    Text("Like the Rest of Focused").tag(NotificationSettings.ListLevel.automatic)
                    Text("Always").tag(NotificationSettings.ListLevel.always)
                    Text("Never").tag(NotificationSettings.ListLevel.muted)
                }
            }
        } label: {
            Text("Correct")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Move this message, or say it is or isn’t phishing")
    }

    private func listLevel(_ list: String, account: MailAccountID) -> Binding<NotificationSettings.ListLevel> {
        Binding(
            get: { model.attention.settings.level(list: list, account: account) },
            set: { level in Task { await model.attention.setLevel(level, list: list, account: account, accounts: model.accounts) } }
        )
    }

    /// Offered only after you moved this message yourself, and only until you answer: a rule is
    /// never made on its own.
    @ViewBuilder private func ruleOffer(_ verdict: StoredVerdict) -> some View {
        // Only a purpose you chose can become a rule: rules never change risk.
        if rule == nil, let correction = correction?.purpose, !verdict.classification.risk.isQuarantined {
            HStack(spacing: 10) {
                Text("Do the same for future mail?").foregroundStyle(.secondary)
                if let list = verdict.listID {
                    Button("From This List") {
                        Task { await model.addRule(.list(list), purpose: correction, account: verdict.account) }
                    }
                    .help("Every message on \(list) goes to \(correction.destinationTitle)")
                }
                if let sender = verdict.fromAddress {
                    Button("From \(sender)") {
                        Task { await model.addRule(.sender(sender), purpose: correction, account: verdict.account) }
                    }
                    .help("Every message from \(sender) goes to \(correction.destinationTitle)")
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.leading, 26)
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 4)).foregroundStyle(.tertiary)
            configuration.title
        }
    }
}

extension ClassificationRule {
    var scopeNoun: String {
        switch scope {
        case .sender: "Sender"
        case .list: "List"
        }
    }
}
