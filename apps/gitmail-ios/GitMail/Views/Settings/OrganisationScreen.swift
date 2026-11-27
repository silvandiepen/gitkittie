import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// Settings ▸ Organisation (GKM-031): active mode per account, retention per category with its
/// dry run, which device runs it, and the history of what it moved, with Undo. The same model
/// as the Mac's Settings ▸ Organisation.
struct OrganisationScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let organisation = model.organisation
        Form {
            if model.accounts.isEmpty {
                Text("Add an account to organise its mail at your provider.").foregroundStyle(.secondary)
            }
            ForEach(model.accounts, id: \.id) { account in
                AccountSection(account: account)
            }
            Section {
                NavigationLink("History") { OrganisationHistoryScreen() }
            } footer: {
                Text("Everything that was moved at your provider, with Undo. Mail content isn’t kept there.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle("Organisation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await organisation.refresh() }
        .sheet(item: Binding(get: { organisation.dryRun }, set: { if $0 == nil { organisation.closeDryRun() } })) { _ in
            DryRunScreen()
        }
        .alert("Organisation", isPresented: Binding(get: { organisation.notice != nil }, set: { if !$0 { organisation.notice = nil } })) {
            Button("OK") { organisation.notice = nil }
        } message: {
            Text(organisation.notice ?? "")
        }
    }
}

private struct AccountSection: View {
    @Environment(AppModel.self) private var model
    let account: MailAccount

    var body: some View {
        let organisation = model.organisation
        let active = organisation.isActive(account.id)
        Section {
            Toggle("Organise Mail at Your Provider", isOn: Binding(
                get: { active },
                set: { on in Task { await organisation.setActive(on, account: account.id) } }))
            if active {
                Text(OrganisationText.pause(organisation.pauses[account.id])).font(.footnote).foregroundStyle(.secondary)
                if !organisation.coordinatesHere(account.id) {
                    Button("Run on \(DeviceWords.thisAtStart) Instead") { Task { await organisation.coordinateHere(account.id) } }
                }
            }
            ForEach(RetentionPolicy.categories, id: \.self) { category in
                NavigationLink {
                    PolicyScreen(account: account.id, category: category)
                } label: {
                    let policy = organisation.policy(for: account.id, category: category)
                    LabeledContent(OrganisationText.category(category), value: policy.isActive ? "On" : "Off")
                }
            }
        } header: {
            Text(account.displayName)
        } footer: {
            Text(active
                 ? "Each policy shows what it would do before it does anything. Flagged mail, mail in a space, conversations, receipts, account security mail and anything Mail isn’t sure about always stay. Nothing is deleted permanently."
                 : "Off: Mail sorts this account on your devices only and nothing moves at your provider.")
        }
    }
}

private struct PolicyScreen: View {
    @Environment(AppModel.self) private var model
    let account: MailAccountID
    let category: MailCategory

    var body: some View {
        let organisation = model.organisation
        let policy = organisation.policy(for: account, category: category)
        Form {
            Section {
                Picker("Older Than", selection: Binding(
                    get: { policy.days },
                    set: { days in Task { await organisation.update(policy, days: days) } })) {
                        ForEach(RetentionPolicy.dayChoices, id: \.self) { Text(OrganisationText.days($0)).tag($0) }
                    }
                Picker("Then", selection: Binding(
                    get: { policy.action },
                    set: { action in Task { await organisation.update(policy, action: action) } })) {
                        ForEach(RetentionAction.allCases, id: \.self) { Text(OrganisationText.action($0)).tag($0) }
                    }
            } footer: {
                Text(policy.action == .trash ? OrganisationText.trashNote : "Changing these turns the policy off until you look at its dry run again.")
            }
            Section {
                if policy.isActive {
                    LabeledContent("Status", value: "On")
                    Button("Turn Off", role: .destructive) { Task { await organisation.turnOff(policy) } }
                } else {
                    Button(organisation.isActive(account) ? "Preview and Turn On" : "Preview") {
                        Task { await organisation.preview(policy) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle(OrganisationText.category(category))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The dry run: exactly what the policy would move now, and what stays and why.
private struct DryRunScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let organisation = model.organisation
        NavigationStack {
            if let dry = organisation.dryRun {
                let preview = dry.preview
                let active = organisation.isActive(dry.policy.account)
                List {
                    Section {
                        Text(OrganisationText.dryRun(preview))
                        if !organisation.changedSinceDryRun.isEmpty {
                            NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange,
                                       text: "Nothing ran: \(CleanupText.messages(organisation.changedSinceDryRun.count)) changed since the dry run. This is the new one.")
                        }
                    } footer: {
                        Text(active
                             ? "Turning it on moves the mail below now, then mail that reaches this age after each check for mail, on the device that runs this account. To keep a message, flag it or add it to a space."
                             : "Turn on “Organise Mail at Your Provider” for this account to use this policy.")
                    }
                    Section("Would Move (\(preview.included.count.formatted()))") {
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
                        Section("Not Affected (\(preview.skipped.count.formatted()))") {
                            ForEach(preview.skipped) { item in Line(item: item, note: item.skip.map(CleanupText.skip)) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.window.ignoresSafeArea())
                .navigationTitle(OrganisationText.category(dry.policy.category))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { organisation.closeDryRun(); dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Turn On") { Task { await organisation.turnOn() } }
                            .disabled(!active)
                    }
                }
            }
        }
    }

    private struct Line: View {
        let item: CleanupItem
        let note: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.summary.from?.displayName ?? "Unknown sender").font(.subheadline.weight(.medium)).lineLimit(1)
                Text(item.summary.subject?.isEmpty == false ? item.summary.subject! : "(No subject)").font(.subheadline).lineLimit(2)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Everything active organisation moved, newest first, with Undo.
private struct OrganisationHistoryScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let organisation = model.organisation
        List {
            if organisation.audit.isEmpty {
                Text("Nothing has been moved at your provider yet.").foregroundStyle(.secondary)
            }
            ForEach(organisation.audit.prefix(100)) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(OrganisationText.summary(entry)).font(.body.weight(.medium))
                    Text([OrganisationText.source(entry, rules: model.senders.rules),
                          model.accounts.first { $0.id == entry.account }?.displayName ?? "A removed account",
                          OrganisationText.trigger(entry),
                          "on your \(entry.device.name)",
                          entry.date.formatted(date: .abbreviated, time: .shortened)].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if let undone = entry.undoneAt {
                        Text("Undone \(undone.formatted(date: .abbreviated, time: .shortened)): \(CleanupText.messages(entry.restored ?? 0)) went back")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if entry.device.id == organisation.device?.id {
                        Button("Undo") { Task { await organisation.undo(entry) } }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .task { await organisation.refresh() }
    }
}
