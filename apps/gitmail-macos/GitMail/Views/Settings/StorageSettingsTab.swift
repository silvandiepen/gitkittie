import MailStore
import SwiftUI

/// Settings ▸ Storage (GKM-066; GKM-036, GKM-060): how far back mail is downloaded, which
/// attachments wait at the provider and what the cache keeps, and the mail folder: where it is,
/// what it takes, and the free space on its disk.
struct StorageSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var storage: OfflineStorage?
    @State private var freed: EvictionResult?
    @State private var working = false
    @State private var folderSize: Int64?

    /// Attachments over this stay at the provider until opened; nil downloads everything.
    private static let thresholds: [Int?] = [1_000_000, 5_000_000, 20_000_000, nil]
    private static let cacheBudgets: [Int64] = [512, 1024, 2048, 5120].map { Int64($0) * 1024 * 1024 }

    var body: some View {
        Form {
            HistoryWindowSection()

            Section {
                Picker("Attachments larger than", selection: threshold) {
                    ForEach(Self.thresholds, id: \.self) { bytes in
                        Text(bytes.map { MessageDate.byteCount($0) + " wait at your provider" } ?? "None: download everything").tag(bytes)
                    }
                }
                Picker("Keep downloaded attachments up to", selection: cacheBudget) {
                    ForEach(Set(Self.cacheBudgets + [model.offlineCacheBudget]).sorted(), id: \.self) { bytes in
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)).tag(bytes)
                    }
                }
                if let storage {
                    LabeledContent("Messages with attachments not downloaded", value: "\(storage.partialMessages)")
                    LabeledContent("Not downloaded", value: MessageDate.byteCount(Int(storage.notDownloadedBytes)))
                    LabeledContent("Downloaded attachments kept here",
                                   value: "\(storage.cachedParts), \(MessageDate.byteCount(Int(storage.cacheBytes)))")
                    LabeledContent("Kept offline, waiting for a connection", value: "\(storage.pinnedWaiting)")
                    LabeledContent("Can be freed") {
                        HStack {
                            Text(MessageDate.byteCount(Int(storage.evictableBytes))).monospacedDigit()
                            Button("Free Up Space") { freeUpSpace() }
                                .disabled(working || storage.evictableBytes == 0)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                if let freed {
                    Text("Freed \(MessageDate.byteCount(Int(freed.removedBytes))) (\(freed.removedParts) attachments). They download again when opened.")
                        .font(.callout)
                }
            } header: {
                Text("Attachments")
            } footer: {
                Text("Your mail folder always holds complete originals of the mail that is all here. Large attachments of other mail download when you open them, or when you keep their message, conversation or space offline, and only those can be freed: they download again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Location") {
                    Text(model.mailFolder?.path(percentEncoded: false) ?? "—")
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Size", value: folderSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                LabeledContent("Free on this disk",
                               value: model.freeDiskSpace.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                HStack {
                    if let folder = model.mailFolder {
                        Button("Show in Finder") { Platform.reveal(folder) }
                    }
                    Spacer()
                    if !model.usesDefaultMailFolder {
                        Button("Use the Default Mail Folder") { Task { await model.useMailFolder(nil) } }
                    }
                    Button("Use Another Mail Folder…") { chooseMailFolder() }
                }
            } header: {
                Text("Mail Folder")
            } footer: {
                Text("Each message is an .eml file with a readable Markdown copy beside it. Mail never deletes mail to make room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 520)
        .task(id: model.mailFolder) {
            storage = await model.offlineStorage()
            folderSize = await model.mailFolderSize()
        }
    }

    private var threshold: Binding<Int?> {
        Binding(get: { model.onDemandThreshold > 0 ? model.onDemandThreshold : nil },
                set: { bytes in Task { await model.setOnDemandThreshold(bytes) } })
    }

    private var cacheBudget: Binding<Int64> {
        Binding(get: { model.offlineCacheBudget }, set: { bytes in
            Task {
                await model.setOfflineCacheBudget(bytes)
                storage = await model.offlineStorage()
            }
        })
    }

    private func freeUpSpace() {
        Task {
            working = true
            freed = await model.freeUpOfflineSpace(keeping: 0)
            storage = await model.offlineStorage()
            working = false
        }
    }

    /// Shows another folder's mail. The current folder stays as it is.
    private func chooseMailFolder() {
        Task {
            guard let url = await Platform.chooseFolder(
                title: "Use Another Mail Folder", prompt: "Use Folder",
                message: "GitKittie Mail shows the accounts and mail in the folder you choose. The current folder stays as it is.") else { return }
            await model.useMailFolder(url)
        }
    }
}

/// How far back Mail downloads (MAIL-072): set it before adding a large mailbox when the Mac
/// is short on space. Older mail stays at the provider and can be downloaded later.
private struct HistoryWindowSection: View {
    @Environment(AppModel.self) private var model
    /// The saved window (0 is all of it); the sync options themselves are not observed.
    @AppStorage(AccountServices.historyDaysKey) private var savedDays = 0
    private static let choices: [Int?] = [30, 90, 365, nil]

    var body: some View {
        Section {
            Picker("Download mail from", selection: Binding(get: { savedDays > 0 ? savedDays : nil }, set: { days in
                savedDays = days ?? 0
                Task { await model.setHistoryDays(days) }
            })) {
                ForEach(Self.choices, id: \.self) { days in
                    Text(Self.title(days)).tag(days)
                }
            }
            .accessibilityIdentifier("historyWindowPicker")
            if savedDays > 0, model.olderNotDownloaded > 0 {
                LabeledContent("Not downloaded: \(model.olderNotDownloaded.formatted()) older messages") {
                    Button("Download Older Mail") {
                        savedDays = 0
                        Task { await model.setHistoryDays(nil) }
                    }
                }
            }
        } header: {
            Text("History")
        } footer: {
            Text("New mail always comes in. Older mail stays at your provider until you choose to download it. Mail already downloaded is kept.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func title(_ days: Int?) -> String {
        switch days {
        case 30: "The last 30 days"
        case 90: "The last 90 days"
        case 365: "The last year"
        default: "All time"
        }
    }
}

/// View ▸ Offline Storage…: Settings ▸ Storage.
struct OfflineStorageCommand: View {
    let navigation: SettingsNavigation
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Offline Storage…") { navigation.show(.storage, with: openSettings) }
    }
}
