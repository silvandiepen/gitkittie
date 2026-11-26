import MailCore
import SwiftUI
import UIKit

/// Accounts, storage and what Mail can and can't do in the background, said plainly
/// (MAIL-051, MAIL-053).
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileSession.self) private var session
    @Environment(MailRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var orderError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    ForEach(model.accounts, id: \.id) { account in
                        NavigationLink {
                            AccountScreen(accountID: account.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                if !account.address.isEmpty, account.address != account.displayName {
                                    Text(account.address).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Account \(account.displayName)")
                            .accessibilityValue(account.address == account.displayName ? "" : account.address)
                        }
                        .accessibilityIdentifier("settingsAccountRow")
                    }
                    // The order of the accounts in the mailbox list (GKM-066): Edit, then drag.
                    .onMove { source, destination in
                        Task {
                            do { try await model.moveAccounts(fromOffsets: source, toOffset: destination) } catch {
                                orderError = "The order couldn’t be saved: \(error.localizedDescription)"
                            }
                        }
                    }
                    if let orderError { NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: orderError) }
                    Button("Add Account") {
                        dismiss()
                        router.showsAddAccount = true
                    }
                }
                Section {
                    NavigationLink("Notifications") { NotificationsScreen() }
                    NavigationLink("Blocked Senders") { BlockedSendersScreen() }
                }
                StorageSection()
                BackgroundSection()
            }
            .scrollContentBackground(.hidden)
            .background(Theme.window.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if model.accounts.count > 1 { ToolbarItem(placement: .topBarLeading) { EditButton() } }
            }
        }
    }
}

/// The limits on what mail takes on this device (MAIL-051, MAIL-068).
private struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileSession.self) private var session

    // Each choice is its own section, with a short footer that explains just that choice (GKM-111).
    // One footer of six sentences (158 pt on an iPhone) often ran past the bottom of the screen;
    // the audit's "partially unsupported" on Form text is only skipped for text wholly inside the
    // list (AccessibilityAuditPolicy), so that footer failed wherever it landed across the edge.
    var body: some View {
        Section {
            Picker("Download mail from", selection: window) {
                ForEach(StorageBudget.historyDayChoices, id: \.self) { choice in
                    Text(choice.map(Self.period) ?? "All time").tag(choice)
                }
            }
            if session.budget.historyWindow != nil, session.olderNotDownloaded > 0 {
                LabeledContent("Not downloaded", value: "\(session.olderNotDownloaded.formatted()) older messages")
                Button("Download Older Mail") { Task { await session.downloadOlderMail() } }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("New mail always comes in.\(windowText)")
        }
        Section {
            Picker("Older mail", selection: history) {
                ForEach(StorageBudget.historyChoices, id: \.self) { choice in
                    Text(choice.map { "Up to " + bytes($0) } ?? "All of it").tag(choice)
                }
            }
        } footer: {
            Text("Older mail is downloaded newest first, up to the limit, per account.")
        }
        Section {
            Toggle("Download Attachments Only When Opened", isOn: attachmentsWhenOpened)
        } footer: {
            Text(attachmentText)
        }
        Section {
            Picker("Cache", selection: cache) {
                // A size chosen before these choices (200 MB) stays listed.
                ForEach(Set(StorageBudget.cacheChoices + [session.budget.cacheBytes]).sorted(), id: \.self) { value in
                    Text(bytes(value)).tag(value)
                }
            }
        } footer: {
            Text("Opened attachments and previews are kept in a cache that is never backed up and is trimmed to its size; pinned attachments stay.")
        }
        Section {
            if let notice = session.storageNotice {
                NoticeLine(systemImage: "externaldrive.badge.exclamationmark", tint: .orange, text: notice)
            }
            LabeledContent("Messages", value: model.totalCount.formatted())
        } footer: {
            Text("Below \(bytes(session.budget.minimumFreeBytes)) free, Mail stops downloading until there is room; it never deletes mail to make room. Your messages are files in Files ▸ On My \(DeviceWords.model) ▸ Mail ▸ Mail.")
        }
    }

    /// What the attachment choice means, for its footer.
    private var attachmentText: String {
        session.budget.attachmentsWhenOpened
            ? "Attachments stay at the provider until you open them."
            : "Attachments over 1 MB stay at the provider until you open them."
    }

    /// What the window means, in words, for its footer.
    private var windowText: String {
        guard let days = session.budget.historyWindow else { return "" }
        return " Mail received more than \(days == 365 ? "a year" : "\(days) days") ago stays at the provider until you download it."
    }

    private static func period(_ days: Int) -> String {
        days == 365 ? "Last year" : "Last \(days) days"
    }

    private var window: Binding<Int?> {
        Binding(get: { session.budget.historyWindow }, set: { value in
            var budget = session.budget
            budget.historyDays = value ?? 0
            Task { await session.setBudget(budget) }
        })
    }

    private var history: Binding<Int64?> {
        Binding(get: { session.budget.historyLimit }, set: { value in
            var budget = session.budget
            budget.historyBytes = value ?? 0
            Task { await session.setBudget(budget) }
        })
    }

    private var attachmentsWhenOpened: Binding<Bool> {
        Binding(get: { session.budget.attachmentsWhenOpened }, set: { value in
            var budget = session.budget
            budget.attachmentsWhenOpened = value
            Task { await session.setBudget(budget) }
        })
    }

    private var cache: Binding<Int64> {
        Binding(get: { session.budget.cacheBytes }, set: { value in
            var budget = session.budget
            budget.cacheBytes = value
            Task { await session.setBudget(budget) }
        })
    }

    /// The limits are whole binary units (500 × 1024 × 1024), so they are shown in the same
    /// units: "500 MB", not the file style's "524.3 MB".
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .memory) }
}

/// What happens when Mail is not on screen: honest, because iOS decides (MAIL-053).
private struct BackgroundSection: View {
    @Environment(MobileSession.self) private var session

    var body: some View {
        Section {
            LabeledContent("Background App Refresh", value: refreshStatus)
            if let notice = session.backgroundNotice {
                NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: notice)
            }
            if let run = session.lastBackgroundRun {
                LabeledContent("Last check") {
                    Text(run.finished.formatted(.relative(presentation: .named)))
                }
                if run.imported > 0 {
                    LabeledContent("Messages it brought in", value: run.imported.formatted())
                }
            }
        } header: {
            Text("When Mail Isn’t Open")
        } footer: {
            Text("While Mail is open it stays connected and new mail arrives at once. When you leave it, iOS closes the connection. iOS then lets Mail check for new mail now and then — how often depends on how you use Mail, on battery and on the network — and catch up on older mail while charging. A message you sent just before leaving still goes out. Notifications can come minutes or hours after the mail; there is no instant push.")
        }
    }

    private var refreshStatus: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: "On"
        case .denied: "Off — turn it on in Settings ▸ General"
        case .restricted: "Not allowed on this device"
        @unknown default: "Unknown"
        }
    }
}
