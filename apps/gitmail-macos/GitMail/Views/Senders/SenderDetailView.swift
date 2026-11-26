import AppKit
import MailClassifier
import MailCompose
import MailCore
import MailStore
import MailUnsubscribe
import SwiftUI

/// One sender or list (GKM-019, GKM-020): what it sends and where that lands, your rules for it,
/// unsubscribe when it is safe, and its recent mail.
struct SenderDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let sender = model.senders.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SenderHeader(sender: sender)
                        SenderStats(sender: sender)
                        SenderRulesSection(sender: sender)
                        UnsubscribeSection(sender: sender)
                        RecentMessages(sender: sender)
                    }
                    .padding(24)
                    .frame(maxWidth: 720, alignment: .leading)
                }
                .id(sender.id)
            } else {
                ContentUnavailableView("Choose a sender", systemImage: "person.2",
                                       description: Text("See what it sends you, make rules for it, or unsubscribe."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }
}

private struct SenderHeader: View {
    let sender: SenderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sender.displayName).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(sender.isList ? "Mailing list \(sender.scope.name)" : sender.scope.name)
                .foregroundStyle(.secondary).textSelection(.enabled)
            if let organisation = sender.organisation {
                Text("From \(organisation). Senders are grouped by domain for reference only; one domain doesn’t prove one company.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SenderStats: View {
    let sender: SenderSummary

    var body: some View {
        SettingsPanel {
            FieldRow(label: "Messages") {
                Text("\(sender.messages) · \(sender.recent) in the last 30 days · \(sender.unread) unread")
            }
            SettingsDivider()
            FieldRow(label: "Seen") {
                Text("\(sender.firstSeen.formatted(date: .abbreviated, time: .omitted)) to \(sender.lastSeen.formatted(date: .abbreviated, time: .omitted))")
            }
            SettingsDivider()
            FieldRow(label: "Where it lands") { Text(categories) }
            SettingsDivider()
            FieldRow(label: "Opened here") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(opened)
                    Text("Only what you open in this app on this Mac. Mail read elsewhere isn’t counted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsDivider()
            FieldRow(label: "Retention") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything is kept.")
                    Text("Suggested for \(sender.mainCategory.title.lowercased()): \(Self.suggestedRetention(sender.mainCategory)). Nothing is ever deleted on its own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var categories: String {
        var parts = MailCategory.allCases.compactMap { category in sender.categories[category].map { "\(category.title) \($0)" } }
        if sender.silenced > 0 { parts.append("\(sender.silenced) muted or archived by your rules") }
        return parts.joined(separator: " · ")
    }

    private var opened: String {
        guard sender.opens > 0, let last = sender.lastOpened else { return "Not opened in this app" }
        return "\(sender.opens == 1 ? "Once" : "\(sender.opens) times"), last \(last.formatted(.relative(presentation: .named)))"
    }

    /// Classification.md, Retention: suggestions only.
    static func suggestedRetention(_ category: MailCategory) -> String {
        switch category {
        case .focused, .transactions: "keep indefinitely"
        case .subscriptions: "90 days"
        case .promotions, .updates: "30 days"
        case .quarantine: "14 days"
        }
    }
}

// MARK: - Rules

private struct SenderRulesSection: View {
    @Environment(AppModel.self) private var model
    let sender: SenderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules").font(.headline)
                Spacer()
                Menu("Add Rule") {
                    ForEach(SenderRuleText.actions, id: \.self) { action in
                        Button(SenderRuleText.title(action)) { Task { await model.senders.propose(action, for: sender) } }
                    }
                    Menu("Always In") {
                        ForEach(MailPurpose.correctable, id: \.self) { purpose in
                            Button(purpose.destinationTitle) { Task { await model.senders.propose(.category(purpose), for: sender) } }
                        }
                    }
                }
                .fixedSize()
            }
            let rules = model.senders.rules(for: sender)
            if rules.isEmpty {
                Text("No rules. Mail from \(sender.isList ? "this list" : "this sender") is sorted like any other. Every rule shows what it would do before it changes anything.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsPanel {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { SettingsDivider() }
                        RuleRow(rule: rule, position: model.senders.position(of: rule), total: model.senders.rules.count)
                    }
                }
            }
        }
    }
}

private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: SenderRule
    let position: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SenderRuleText.title(rule.action)).font(.body.weight(.medium))
                    Text("Rule \(position) of \(total). " + SenderRuleText.explanation(rule.action))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("On", isOn: Binding(get: { rule.isEnabled },
                                           set: { on in Task { await model.senders.proposeEnabled(on, rule: rule) } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(rule.isEnabled ? "Turn this rule off" : "Turn this rule on")
                Menu {
                    Button("Move Up") { Task { await model.senders.proposeMove(rule, by: -1) } }.disabled(position == 1)
                    Button("Move Down") { Task { await model.senders.proposeMove(rule, by: 1) } }.disabled(position == total)
                    Divider()
                    Button("Remove Rule…", role: .destructive) { Task { await model.senders.proposeRemoval(of: rule) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Rule options")
            }
            if rule.action.canArchiveAtProvider {
                let active = model.organisation.isActive(rule.account)
                Toggle("Also archive at your mail provider", isOn: Binding(
                    get: { rule.archiveAtProvider },
                    set: { on in Task { await model.senders.proposeArchiveAtProvider(on, rule: rule) } }))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    // Active organisation (GKM-031): only with active mode on for the account;
                    // a rule already set can always be turned back.
                    .disabled(!active && !rule.archiveAtProvider)
                    .help("Off: mail stays where it is at your provider and only this app hides it.")
                if !active {
                    Text(rule.archiveAtProvider
                         ? "Paused: active organisation is off for this account, so mail stays where it is at your provider. Turn it on in Settings ▸ Organisation."
                         : "To archive at your provider, turn on active organisation for this account in Settings ▸ Organisation.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !rule.excluded.isEmpty {
                Text(rule.excluded.count == 1 ? "1 message kept out of this rule" : "\(rule.excluded.count) messages kept out of this rule")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Unsubscribe

private struct UnsubscribeSection: View {
    @Environment(AppModel.self) private var model
    let sender: SenderSummary
    @State private var option: UnsubscribeModel.Option?
    @State private var approval: Approval?

    enum Approval: Identifiable {
        case oneClick(URL)
        case mailto(ComposeDraft)
        case manual(URL)
        var id: String {
            switch self {
            case .oneClick(let url), .manual(let url): url.absoluteString
            case .mailto(let draft): draft.id.rawValue
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unsubscribe").font(.headline)
            if let request = model.senders.unsubscribe.request(for: sender) { RequestStatus(request: request) }
            if let option {
                switch option.assessment.outcome {
                case .offer(let method, let alternatives):
                    HStack(spacing: 10) {
                        Button(label(method)) { approval = approval(for: method, source: option.source) }
                        ForEach(alternatives, id: \.self) { alternative in
                            Button(label(alternative)) { approval = approval(for: alternative, source: option.source) }
                                .buttonStyle(.link)
                        }
                        Button("Mute Instead") { Task { await model.senders.propose(.mute, for: sender) } }
                            .buttonStyle(.link)
                    }
                    ForEach(option.assessment.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                case .refused(let refusal):
                    Notice(systemImage: option.assessment.suggestsReportingJunk ? "exclamationmark.shield" : "info.circle",
                           tint: option.assessment.suggestsReportingJunk ? .orange : .secondary, text: refusal.explanation)
                    HStack(spacing: 10) {
                        if option.assessment.suggestsReportingJunk, let message = option.source?.message {
                            Button("Report as Junk") { Task { await model.reportJunk(message) } }
                        }
                        Button("Mute") { Task { await model.senders.propose(.mute, for: sender) } }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: sender.id) { option = await model.senders.unsubscribe.option(for: sender) }
        .sheet(item: $approval) { approval in
            UnsubscribeApprovalSheet(sender: sender, approval: approval)
        }
    }

    private func label(_ method: UnsubscribeMethod) -> String {
        switch method {
        case .oneClick: "Unsubscribe…"
        case .mailto: "Unsubscribe by Email…"
        case .manual: "Open the List’s Page…"
        }
    }

    private func approval(for method: UnsubscribeMethod, source: SenderListHeaders?) -> Approval {
        switch method {
        case .oneClick(let url): .oneClick(url)
        case .manual(let url): .manual(url)
        case .mailto(let address, let subject, let body):
            .mailto(model.senders.unsubscribe.mailtoDraft(address: address, subject: subject, body: body, for: sender, source: source))
        }
    }
}

private struct RequestStatus: View {
    @Environment(AppModel.self) private var model
    let request: UnsubscribeRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("\(request.state.title) · \(request.requestedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout.weight(.medium))
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            Text(request.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if request.state == .pending || request.state == .requested {
                HStack(spacing: 12) {
                    Button("It Stopped") { Task { await model.senders.unsubscribe.mark(request, confirmed: true) } }
                    Button("Still Getting Mail") { Task { await model.senders.unsubscribe.mark(request, confirmed: false) } }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    private var icon: String {
        switch request.state {
        case .requested, .pending: "clock"
        case .confirmed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch request.state {
        case .requested, .pending: .secondary
        case .confirmed: .green
        case .failed: .orange
        }
    }
}

/// What will be sent, and to whom, before anything is: one request, one message, or a page you
/// finish yourself.
private struct UnsubscribeApprovalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sender: SenderSummary
    let approval: UnsubscribeSection.Approval
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch approval {
            case .oneClick(let url):
                SheetHeader(title: "Unsubscribe from \(sender.displayName)?",
                            detail: "GitKittie Mail sends one request to the list’s unsubscribe address, as the list asks for in its mail. No cookies, passwords or other details are sent, and no page is opened.")
                SettingsPanel {
                    FieldRow(label: "Sends to") { Text(url.host ?? url.absoluteString).textSelection(.enabled) }
                    SettingsDivider()
                    FieldRow(label: "Address") { Text(url.absoluteString).font(.caption).lineLimit(3).textSelection(.enabled) }
                }
                Text("A list that accepts the request isn’t proof yet. You’ll see here whether its mail stops.")
                    .font(.callout).foregroundStyle(.secondary)
                buttons("Unsubscribe") {
                    await model.senders.unsubscribe.approveOneClick(url, for: sender)
                }
            case .mailto(let draft):
                SheetHeader(title: "Send an unsubscribe message?",
                            detail: "This message goes through your Outbox like any other. Check the address it’s sent from.")
                SettingsPanel {
                    FieldRow(label: "From") { Text(draft.from?.address ?? "No address for this account").textSelection(.enabled) }
                    SettingsDivider()
                    FieldRow(label: "To") { Text(draft.to.map(\.address).joined(separator: ", ")).textSelection(.enabled) }
                    SettingsDivider()
                    FieldRow(label: "Subject") { Text(draft.subject).textSelection(.enabled) }
                    SettingsDivider()
                    FieldRow(label: "Message") { Text(draft.body).textSelection(.enabled) }
                }
                buttons("Send") { await model.senders.unsubscribe.sendMailto(draft, for: sender) }
                    .disabled(draft.from == nil)
            case .manual(let url):
                SheetHeader(title: "Finish on the list’s page?",
                            detail: "This list has no one-click unsubscribe, so its page opens in your browser. Don’t enter a password there: unsubscribing never needs one.")
                Notice(systemImage: "exclamationmark.triangle", tint: .orange,
                       text: "Opening the page tells the list you read its mail. If you’re unsure, mute it here instead.")
                SettingsPanel {
                    FieldRow(label: "Opens") { Text(url.absoluteString).font(.caption).lineLimit(3).textSelection(.enabled) }
                }
                buttons("Open in Browser") {
                    NSWorkspace.shared.open(url)
                    await model.senders.unsubscribe.openedManually(url, for: sender)
                }
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(Theme.window)
    }

    private func buttons(_ title: String, action: @escaping () async -> Void) -> some View {
        HStack {
            Button("Mute Instead") {
                dismiss()
                Task { await model.senders.propose(.mute, for: sender) }
            }
            .buttonStyle(.link)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(title) {
                working = true
                Task {
                    await action()
                    working = false
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(working)
        }
    }
}

// MARK: - Recent mail

private struct RecentMessages: View {
    @Environment(AppModel.self) private var model
    let sender: SenderSummary
    @State private var messages: [MessageSummary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent mail").font(.headline)
            SettingsPanel {
                ForEach(Array(messages.prefix(20).enumerated()), id: \.element.id) { index, message in
                    if index > 0 { SettingsDivider() }
                    HStack {
                        Text(message.subject?.isEmpty == false ? message.subject! : "(No subject)")
                            .fontWeight(message.isUnread ? .semibold : .regular)
                            .lineLimit(1)
                        Spacer()
                        Text(message.date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
            }
        }
        .task(id: sender) { messages = await model.senders.messages(of: sender) }
    }
}
