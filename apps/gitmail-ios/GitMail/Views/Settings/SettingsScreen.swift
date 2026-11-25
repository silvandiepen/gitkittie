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
                        }
                    }
                    Button("Add Account") {
                        dismiss()
                        router.showsAddAccount = true
                    }
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
            }
        }
    }
}

/// The limits on what mail takes on this device (MAIL-051, MAIL-068).
private struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileSession.self) private var session

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
            Picker("Older mail", selection: history) {
                ForEach(StorageBudget.historyChoices, id: \.self) { choice in
                    Text(choice.map { "Up to " + bytes($0) } ?? "All of it").tag(choice)
                }
            }
            Picker("Cache", selection: cache) {
                ForEach([Int64(200), 500, 1000].map { $0 * 1024 * 1024 }, id: \.self) { value in
                    Text(bytes(value)).tag(value)
                }
            }
            if let notice = session.storageNotice {
                NoticeLine(systemImage: "externaldrive.badge.exclamationmark", tint: .orange, text: notice)
            }
            LabeledContent("Messages", value: model.totalCount.formatted())
        } header: {
            Text("Storage")
        } footer: {
            Text("New mail always comes in.\(windowText) Older mail is downloaded newest first, up to the limit, per account. Attachment previews are kept in a cache that is never backed up and is trimmed to its size. Below \(bytes(session.budget.minimumFreeBytes)) free, Mail stops downloading until there is room; it never deletes mail to make room. Your messages are files in Files ▸ On My \(DeviceWords.model) ▸ Mail ▸ Mail.")
        }
    }

    /// What the window means, in words, for the footer.
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
