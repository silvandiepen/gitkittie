import MailCore
import MailStore
import SwiftUI

/// An account's mailboxes on iPhone and iPad (GKM-066, MAIL-093..095), the same choices as the
/// Mac's Settings: which folders sync and show, their order (Edit, then drag), the special
/// folders, and folders made, renamed and deleted at the provider.
struct AccountMailboxesScreen: View {
    @Environment(AppModel.self) private var model
    let accountID: MailAccountID
    @State private var creating = false
    @State private var newName = ""
    @State private var error: String?
    @State private var isWorking = false

    private var account: MailAccount? { model.accounts.first { $0.id == accountID } }

    var body: some View {
        Form {
            if let account {
                let folders = model.settingsFolders(of: account)
                if folders.isEmpty {
                    Section {
                        Text(account.connection == nil ? "This account isn’t connected, so it has no folders at the provider." : "Folders appear after the first sync.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(folders, id: \.name) { folder in
                            NavigationLink {
                                FolderSettingsScreen(accountID: accountID, folderName: folder.name)
                            } label: {
                                FolderSettingsRow(folder: folder, settings: account.mailboxSettings)
                            }
                            .accessibilityIdentifier("mailboxRow-\(folder.name)")
                        }
                        .onMove { source, destination in
                            run("The order couldn’t be saved") {
                                try await model.moveFolders(fromOffsets: source, toOffset: destination, account: accountID)
                            }
                        }
                        if account.connection != nil {
                            Button("New Folder…") {
                                newName = ""
                                creating = true
                            }
                            .accessibilityIdentifier("newFolderButton")
                        }
                        if !account.mailboxSettings.order.isEmpty {
                            Button("Use the Provider’s Order") {
                                run("The order couldn’t be saved") { try await model.resetFolderOrder(account: accountID) }
                            }
                        }
                        if let error { NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: error) }
                    } header: {
                        Text("Folders")
                    } footer: {
                        Text("Tap Edit to change the order in the mailbox list. A folder that doesn’t sync keeps the mail already downloaded; nothing new comes in from it. The inbox always syncs.")
                    }
                    SpecialFoldersSection(account: account)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle("Mailboxes")
        .toolbar {
            if isWorking { ToolbarItem(placement: .topBarTrailing) { ProgressView() } }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .alert("New Folder", isPresented: $creating) {
            TextField("Name", text: $newName)
                .accessibilityIdentifier("newFolderName")
            Button("Cancel", role: .cancel) {}
            Button("Create") { create() }
        } message: {
            Text("The folder is made at your provider, so your other apps and devices see it too.")
        }
    }

    private func create() {
        let name = newName
        error = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await model.createFolder(named: name, in: nil, account: accountID) } catch {
                self.error = FolderEditText.message(error, doing: "made")
            }
        }
    }

    private func run(_ failure: String, _ work: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task {
            do { try await work() } catch { self.error = "\(failure): \(error.localizedDescription)" }
        }
    }
}

/// A folder in the list: its name at its level, and what is not the default about it.
private struct FolderSettingsRow: View {
    let folder: SyncedFolder
    let settings: MailboxSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: FolderLook.icon(folder.role))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.role == "inbox" ? "Inbox" : folder.displayName)
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(max(0, folder.path.count - 1)) * 14)
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        if let role = folder.role, role != "inbox", role != folder.detectedRole { notes.append(FolderLook.title(role)) }
        if !settings.syncs(folder.name, detectedRole: folder.detectedRole) { notes.append("Doesn’t sync") }
        if !settings.shows(folder.name) { notes.append("Hidden") }
        return notes
    }
}

/// Sent, Drafts, Archive, Trash and Junk: the provider's, or one chosen by hand (MAIL-094).
private struct SpecialFoldersSection: View {
    @Environment(AppModel.self) private var model
    let account: MailAccount
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(MailboxSettings.choosableRoles, id: \.self) { role in
                Picker(FolderLook.title(role), selection: special(role)) {
                    Text(automaticTitle(role)).tag(String?.none)
                    ForEach(model.specialFolderCandidates(of: account), id: \.name) { folder in
                        Text(folder.path.joined(separator: " / ")).tag(Optional(folder.name))
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("specialFolder-\(role)")
            }
            if let error { NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: error) }
        } header: {
            Text("Special Folders")
        } footer: {
            Text("Automatic is the folder your provider marks for it. Archive, Move to Trash, Junk, Clean Up and the copy of sent mail use the folder chosen here. Drafts are kept on \(DeviceWords.this), so the Drafts folder only changes its icon.")
        }
        .disabled(account.connection == nil)
    }

    private func automaticTitle(_ role: String) -> String {
        if let detected = model.detectedFolder(for: role, of: account) { return "Automatic (\(detected.path.joined(separator: " / ")))" }
        return role == "archive" || role == "trash" ? "Automatic (made when first used)" : "Automatic (none)"
    }

    private func special(_ role: String) -> Binding<String?> {
        Binding(get: { account.mailboxSettings.specialFolders[role] }, set: { folder in
            error = nil
            Task {
                do { try await model.setSpecialFolder(folder, for: role, account: account.id) } catch {
                    self.error = "The choice couldn’t be saved: \(error.localizedDescription)"
                }
            }
        })
    }
}

/// One folder: whether it syncs and shows, and renaming, a folder inside it, or deleting it.
struct FolderSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountID: MailAccountID
    @State var folderName: String
    @State private var renaming = false
    @State private var creating = false
    @State private var name = ""
    @State private var confirmingDelete = false
    @State private var storedCount: Int?
    @State private var isWorking = false
    @State private var error: String?

    init(accountID: MailAccountID, folderName: String) {
        self.accountID = accountID
        _folderName = State(initialValue: folderName)
    }

    private var account: MailAccount? { model.accounts.first { $0.id == accountID } }
    private var folder: SyncedFolder? { account.flatMap { model.settingsFolders(of: $0).first { $0.name == folderName } } }

    var body: some View {
        Form {
            if let account, let folder {
                let settings = account.mailboxSettings
                let editable = account.connection != nil && !MailboxSettings.fixedRoles.contains(folder.detectedRole ?? "")
                Section {
                    Toggle("Sync", isOn: Binding(get: { settings.syncs(folder.name, detectedRole: folder.detectedRole) }, set: { value in
                        run("The choice couldn’t be saved") { try await model.setSyncs(value, folder: folder.name, account: accountID) }
                    }))
                    .disabled(folder.detectedRole == "inbox" || account.connection == nil)
                    .accessibilityIdentifier("folderSyncToggle")
                    Toggle("Show in Mailboxes", isOn: Binding(get: { settings.shows(folder.name) }, set: { value in
                        run("The choice couldn’t be saved") { try await model.setShows(value, folder: folder.name, account: accountID) }
                    }))
                    .accessibilityIdentifier("folderShowToggle")
                } footer: {
                    Text(folder.detectedRole == "inbox"
                         ? "The inbox always syncs."
                         : "A folder that doesn’t sync keeps the mail already downloaded; nothing new comes in from it, and its read and flag changes aren’t checked.")
                }
                if editable {
                    Section {
                        Button("Rename…") {
                            name = folder.displayName
                            renaming = true
                        }
                        .accessibilityIdentifier("renameFolderButton")
                        Button("New Folder Inside…") {
                            name = ""
                            creating = true
                        }
                        Button("Delete Folder…", role: .destructive) {
                            storedCount = nil
                            confirmingDelete = true
                            Task { storedCount = await model.storedCount(in: folder.name, account: accountID) }
                        }
                        .accessibilityIdentifier("deleteFolderButton")
                    } header: {
                        Text("At \(ProviderDeletionText.providerName(of: account))")
                    } footer: {
                        Text("These change the folder at your provider, for every app and device.")
                    }
                }
                if let error {
                    Section { NoticeLine(systemImage: "exclamationmark.triangle", tint: .orange, text: error) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle(folder.map { $0.role == "inbox" ? "Inbox" : $0.displayName } ?? "Folder")
        .toolbar { if isWorking { ToolbarItem(placement: .topBarTrailing) { ProgressView() } } }
        .alert("Rename Folder", isPresented: $renaming) {
            TextField("Name", text: $name).accessibilityIdentifier("renameFolderName")
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename() }
        } message: {
            Text("The mail already on \(DeviceWords.this) stays, under the new name.")
        }
        .alert("New Folder Inside", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createInside() }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) { delete() }
                .accessibilityIdentifier("confirmDeleteFolder")
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteTitle: String { "Delete “\(folder?.displayName ?? "")”?" }

    private var deleteMessage: String {
        guard let account else { return "" }
        let provider = ProviderDeletionText.providerName(of: account)
        let mail = storedCount.map { $0 == 0 ? "" : " Its \($0 == 1 ? "1 message" : "\($0.formatted()) messages") downloaded here stay on \(DeviceWords.this), marked as deleted there." } ?? ""
        return "The folder and all the mail in it are deleted at \(provider), for every app and device. This can’t be undone.\(mail)"
    }

    private func rename() {
        guard let folder else { return }
        let newName = name
        work(doing: "renamed") { folderName = try await model.renameFolder(folder, to: newName, account: accountID) }
    }

    private func createInside() {
        guard let folder else { return }
        let newName = name
        work(doing: "made") { try await model.createFolder(named: newName, in: folder, account: accountID) }
    }

    private func delete() {
        guard let folder else { return }
        work(doing: "deleted") {
            try await model.deleteFolder(folder, account: accountID)
            dismiss()
        }
    }

    private func work(doing what: String, _ body: @escaping @MainActor () async throws -> Void) {
        error = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await body() } catch { self.error = FolderEditText.message(error, doing: what) }
        }
    }

    private func run(_ failure: String, _ work: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task {
            do { try await work() } catch { self.error = "\(failure): \(error.localizedDescription)" }
        }
    }
}
