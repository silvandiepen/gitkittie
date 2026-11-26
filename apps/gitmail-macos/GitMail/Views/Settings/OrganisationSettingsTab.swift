import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// Settings ▸ Organisation (GKM-031): active mode per account, retention per category with its
/// dry run, which device runs it, and the history of everything it moved, with Undo.
struct OrganisationSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let organisation = model.organisation
        Form {
            if model.accounts.isEmpty {
                Text("Add an account to organise its mail at your provider.").foregroundStyle(.secondary)
            }
            ForEach(model.accounts, id: \.id) { account in
                AccountOrganisationSection(account: account)
            }
            HistorySection()
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
        .task { await organisation.refresh() }
        .sheet(item: Binding(get: { organisation.dryRun }, set: { if $0 == nil { organisation.closeDryRun() } })) { _ in
            RetentionDryRunSheet()
        }
        .alert("Organisation", isPresented: Binding(get: { organisation.notice != nil }, set: { if !$0 { organisation.notice = nil } })) {
            Button("OK") { organisation.notice = nil }
        } message: {
            Text(organisation.notice ?? "")
        }
    }
}

private struct AccountOrganisationSection: View {
    @Environment(AppModel.self) private var model
    let account: MailAccount

    var body: some View {
        let organisation = model.organisation
        let active = organisation.isActive(account.id)
        Section {
            Toggle("Organise mail at your provider", isOn: Binding(
                get: { active },
                set: { on in Task { await organisation.setActive(on, account: account.id) } }))
            if active {
                LabeledContent("Runs on") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(OrganisationText.pause(organisation.pauses[account.id]))
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        if !organisation.coordinatesHere(account.id) {
                            Button("Run on \(DeviceWords.thisAtStart) Instead") {
                                Task { await organisation.coordinateHere(account.id) }
                            }
                        }
                    }
                }
            }
            ForEach(RetentionPolicy.categories, id: \.self) { category in
                PolicyRow(policy: organisation.policy(for: account.id, category: category), accountActive: active)
            }
        } header: {
            Text(account.displayName)
        } footer: {
            Text(active
                 ? "Each policy below shows what it would do before it does anything. Flagged mail, mail in a space, conversations, receipts, account security mail and anything Mail isn’t sure about always stay. Nothing is deleted permanently."
                 : "Off: Mail sorts this account on your devices only and nothing moves at your provider. Policies below show what they would do.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PolicyRow: View {
    @Environment(AppModel.self) private var model
    let policy: RetentionPolicy
    let accountActive: Bool

    var body: some View {
        let organisation = model.organisation
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(OrganisationText.category(policy.category))
                Text(policy.isActive ? "On: \(OrganisationText.policy(policy).lowercased())" : "Off")
                    .font(.caption).foregroundStyle(policy.isActive ? .primary : .secondary)
            }
            Spacer()
            Picker("Older than", selection: Binding(
                get: { policy.days },
                set: { days in Task { await organisation.update(policy, days: days) } })) {
                    ForEach(RetentionPolicy.dayChoices, id: \.self) { Text(OrganisationText.days($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("How old mail must be")
            Picker("Then", selection: Binding(
                get: { policy.action },
                set: { action in Task { await organisation.update(policy, action: action) } })) {
                    ForEach(RetentionAction.allCases, id: \.self) { Text(OrganisationText.action($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            if policy.isActive {
                Button("Turn Off") { Task { await organisation.turnOff(policy) } }
            } else {
                Button(accountActive ? "Preview & Turn On…" : "Preview…") { Task { await organisation.preview(policy) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OrganisationText.category(policy.category))
    }
}

/// The dry run: exactly what the policy would move now, and what stays and why.
private struct RetentionDryRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let organisation = model.organisation
        if let dry = organisation.dryRun {
            let preview = dry.preview
            let active = organisation.isActive(dry.policy.account)
            VStack(alignment: .leading, spacing: 14) {
                SheetHeader(title: OrganisationText.policy(dry.policy),
                            detail: OrganisationText.dryRun(preview))
                if !organisation.changedSinceDryRun.isEmpty {
                    Notice(systemImage: "exclamationmark.triangle", tint: .orange,
                           text: "Nothing ran: \(CleanupText.messages(organisation.changedSinceDryRun.count)) changed since the dry run. This is the new one.")
                }
                if dry.policy.action == .trash {
                    Text(OrganisationText.trashNote).font(.callout).foregroundStyle(.secondary)
                }
                List {
                    Section("Would move (\(preview.included.count.formatted()))") {
                        ForEach(preview.included) { item in Line(item: item, note: item.note) }
                    }
                    if !preview.protected.isEmpty {
                        Section("Stays (\(preview.protected.count.formatted()))") {
                            ForEach(preview.protected) { item in
                                Line(item: item, note: item.protections.map(CleanupText.protection).joined(separator: " · "))
                            }
                        }
                    }
                    if !preview.skipped.isEmpty {
                        Section("Not affected (\(preview.skipped.count.formatted()))") {
                            ForEach(preview.skipped) { item in Line(item: item, note: item.skip.map(CleanupText.skip)) }
                        }
                    }
                }
                .frame(minHeight: 280)
                Text(active
                     ? "Turning it on moves the mail listed above now, then mail that reaches this age after each check for mail, on the device that runs this account. To keep a message, flag it or add it to a space. Every step is listed in History, where you can undo it."
                     : "Turn on “Organise mail at your provider” for this account to use this policy.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Close") { organisation.closeDryRun(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(preview.included.isEmpty ? "Turn On" : "Turn On and \(CleanupText.verb(preview.operation, count: preview.included.count))") {
                        Task { await organisation.turnOn() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!active)
                }
            }
            .padding(22)
            .frame(width: 620)
            .frame(maxHeight: 720)
            .background(Theme.window)
        }
    }

    private struct Line: View {
        let item: CleanupItem
        let note: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.summary.from?.displayName ?? "Unknown sender").font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(MessageDate.short(item.summary.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(item.summary.subject?.isEmpty == false ? item.summary.subject! : "(No subject)").font(.callout).lineLimit(1)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Everything active organisation moved, newest first, with Undo.
private struct HistorySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let organisation = model.organisation
        Section {
            if organisation.audit.isEmpty {
                Text("Nothing has been moved at your provider yet.").foregroundStyle(.secondary)
            }
            ForEach(organisation.audit.prefix(100)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(OrganisationText.summary(entry)).font(.body.weight(.medium))
                        Text([OrganisationText.source(entry, rules: model.senders.rules),
                              accountName(entry.account),
                              OrganisationText.trigger(entry),
                              "on your \(entry.device.name)"].joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let undone = entry.undoneAt {
                            Text("Undone \(undone.formatted(date: .abbreviated, time: .shortened)): \(CleanupText.messages(entry.restored ?? 0)) went back")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if !entry.isUndone, entry.device.id == organisation.device?.id {
                        Button("Undo") { Task { await organisation.undo(entry) } }
                    }
                }
            }
        } header: {
            Text("History")
        } footer: {
            Text("What was moved, when, by which policy or rule and on which device. Mail content isn’t kept here. Undo puts the messages back where they were, if they haven’t moved since.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func accountName(_ id: MailAccountID) -> String {
        model.accounts.first { $0.id == id }?.displayName ?? "A removed account"
    }
}
