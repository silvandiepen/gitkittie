import MailCore
import MailStore
import SwiftUI

/// An account's mailboxes (GKM-066, MAIL-093..095): which folders sync and show in the sidebar,
/// in what order (drag them), which folder is Sent, Drafts, Archive, Trash and Junk, and folders
/// made, renamed and deleted at the provider.
struct AccountMailboxesPane: View {
    @Environment(AppModel.self) private var model
    let account: MailAccount
    @State private var selection: String?
    @State private var naming: FolderNaming?
    @State private var deleting: SyncedFolder?
    @State private var deletingCount: Int?
    @State private var isWorking = false
    @State private var error: String?

    private var folders: [SyncedFolder] { model.settingsFolders(of: account) }
    private var settings: MailboxSettings { account.mailboxSettings }
    private var selectedFolder: SyncedFolder? { selection.flatMap { name in folders.first { $0.name == name } } }
    private var isConnected: Bool { account.connection != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if folders.isEmpty {
                Text(isConnected ? "Folders appear after the first sync." : "This account isn’t connected, so it has no folders at the provider.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                folderList
                toolbar
                if let error { SheetError(message: error) }
                specialFolders
            }
        }
        .sheet(item: $naming) { naming in
            FolderNameSheet(naming: naming) { name in try await commit(naming, name: name) }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { folder in
            Button("Delete Folder", role: .destructive) { delete(folder) }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text(deleteMessage)
        }
    }

    // MARK: The folders

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Folder")
                Spacer()
                Text("Sync").frame(width: 52)
                Text("Show").frame(width: 52)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            List(selection: $selection) {
                ForEach(folders, id: \.name) { folder in
                    row(folder).tag(folder.name)
                }
                .onMove { source, destination in
                    run("The order couldn’t be saved") {
                        try await model.moveFolders(fromOffsets: source, toOffset: destination, account: account.id)
                    }
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .frame(minHeight: 190)
            .accessibilityIdentifier("settingsMailboxList")
            Text("Drag folders to change their order in the sidebar. A folder that doesn’t sync keeps the mail already downloaded; nothing new comes in from it. The inbox always syncs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ folder: SyncedFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FolderLook.icon(folder.role))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(folder.role == "inbox" ? "Inbox" : folder.displayName)
                .lineLimit(1)
                .padding(.leading, CGFloat(max(0, folder.path.count - 1)) * 14)
            if let role = folder.role, role != "inbox", role != folder.detectedRole {
                Text(FolderLook.title(role)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Sync \(folder.displayName)", isOn: syncs(folder))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(folder.detectedRole == "inbox" || !isConnected)
                .frame(width: 52)
            Toggle("Show \(folder.displayName) in the sidebar", isOn: shows(folder))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 52)
        }
        .accessibilityElement(children: .contain)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu("New Folder") {
                Button("New Folder…") { naming = .create(parent: nil) }
                if let parent = selectedFolder, parent.detectedRole != "inbox" {
                    Button("New Folder Inside “\(parent.displayName)”…") { naming = .create(parent: parent) }
                }
            }
            .fixedSize()
            Button("Rename…") { if let folder = selectedFolder { naming = .rename(folder) } }
                .disabled(!canEdit(selectedFolder))
            Button("Delete…") {
                guard let folder = selectedFolder else { return }
                deletingCount = nil
                deleting = folder
                Task { deletingCount = await model.storedCount(in: folder.name, account: account.id) }
            }
            .disabled(!canEdit(selectedFolder))
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
            Button("Reset Order") {
                run("The order couldn’t be saved") { try await model.resetFolderOrder(account: account.id) }
            }
            .disabled(settings.order.isEmpty)
        }
        .disabled(!isConnected || isWorking)
    }

    /// The inbox and the provider's All Mail and Starred are never renamed or deleted here.
    private func canEdit(_ folder: SyncedFolder?) -> Bool {
        guard let folder else { return false }
        return !MailboxSettings.fixedRoles.contains(folder.detectedRole ?? "")
    }

    // MARK: Special folders (MAIL-094)

    private var specialFolders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Special folders").font(.subheadline.weight(.medium))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(MailboxSettings.choosableRoles, id: \.self) { role in
                    GridRow {
                        Text(FolderLook.title(role)).foregroundStyle(.secondary)
                        Picker(FolderLook.title(role), selection: special(role)) {
                            Text(automaticTitle(role)).tag(String?.none)
                            Divider()
                            ForEach(model.specialFolderCandidates(of: account), id: \.name) { folder in
                                Text(folder.path.joined(separator: " / ")).tag(Optional(folder.name))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                }
            }
            Text("Automatic is the folder your provider marks for it. Archive, Move to Trash, Junk, Clean Up and the copy of sent mail use the folder chosen here. Drafts are kept on this Mac, so the Drafts folder only changes its icon.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!isConnected)
    }

    private func automaticTitle(_ role: String) -> String {
        if let detected = model.detectedFolder(for: role, of: account) {
            return "Automatic (\(detected.path.joined(separator: " / ")))"
        }
        switch role {
        case "archive": return "Automatic (Archive, made when first used)"
        case "trash": return "Automatic (Trash, made when first used)"
        default: return "Automatic (none)"
        }
    }

    // MARK: Bindings

    private func syncs(_ folder: SyncedFolder) -> Binding<Bool> {
        Binding(get: { settings.syncs(folder.name, detectedRole: folder.detectedRole) }, set: { value in
            run("The choice couldn’t be saved") { try await model.setSyncs(value, folder: folder.name, account: account.id) }
        })
    }

    private func shows(_ folder: SyncedFolder) -> Binding<Bool> {
        Binding(get: { settings.shows(folder.name) }, set: { value in
            run("The choice couldn’t be saved") { try await model.setShows(value, folder: folder.name, account: account.id) }
        })
    }

    private func special(_ role: String) -> Binding<String?> {
        Binding(get: { settings.specialFolders[role] }, set: { folder in
            run("The choice couldn’t be saved") { try await model.setSpecialFolder(folder, for: role, account: account.id) }
        })
    }

    private func run(_ failure: String, _ work: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task {
            do { try await work() } catch { self.error = "\(failure): \(error.localizedDescription)" }
        }
    }

    // MARK: Folder edits (MAIL-095)

    private func commit(_ naming: FolderNaming, name: String) async throws {
        error = nil
        isWorking = true
        defer { isWorking = false }
        switch naming {
        case .create(let parent):
            selection = try await model.createFolder(named: name, in: parent, account: account.id)
        case .rename(let folder):
            selection = try await model.renameFolder(folder, to: name, account: account.id)
        }
    }

    private func delete(_ folder: SyncedFolder) {
        deleting = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await model.deleteFolder(folder, account: account.id)
                selection = nil
            } catch {
                self.error = FolderEditText.message(error, doing: "deleted")
            }
        }
    }

    private var deleteTitle: String {
        "Delete “\(deleting?.displayName ?? "")” at \(ProviderDeletionText.providerName(of: account))?"
    }

    private var deleteMessage: String {
        let provider = ProviderDeletionText.providerName(of: account)
        let mail = deletingCount.map { $0 == 0 ? "" : " Its \($0 == 1 ? "1 message" : "\($0.formatted()) messages") downloaded here stay on this Mac, marked as deleted there\(account.removesDeletedMail ? ", until Remove mail deleted elsewhere removes them on the next sync" : "")." } ?? ""
        return "The folder and all the mail in it are deleted at \(provider), for every app and device. This can’t be undone.\(mail)"
    }
}

/// What the name sheet is for.
enum FolderNaming: Identifiable {
    case create(parent: SyncedFolder?)
    case rename(SyncedFolder)

    var id: String {
        switch self {
        case .create(let parent): "create-\(parent?.name ?? "")"
        case .rename(let folder): "rename-\(folder.name)"
        }
    }
}

/// Asks for a folder's name; the change is made at the provider before the sheet closes.
struct FolderNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let naming: FolderNaming
    let commit: (String) async throws -> Void
    @State private var name = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: title, detail: detail)
            SettingsPanel {
                FieldRow(label: "Name") {
                    TextField("Name", text: $name, prompt: Text("Folder name"))
                        .labelsHidden()
                        .accessibilityIdentifier("folderNameField")
                        .onSubmit(save)
                }
            }
            if let error { SheetError(message: error) }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { if case .rename(let folder) = naming { name = folder.displayName } }
    }

    private var title: String {
        switch naming {
        case .create(nil): "New Folder"
        case .create(let parent?): "New Folder Inside “\(parent.displayName)”"
        case .rename(let folder): "Rename “\(folder.displayName)”"
        }
    }

    private var detail: String {
        switch naming {
        case .create: "The folder is made at your provider, so your other apps and devices see it too."
        case .rename: "The folder is renamed at your provider. The mail already on this Mac stays, under the new name."
        }
    }

    private var actionTitle: String {
        if case .rename = naming { return "Rename" }
        return "Create"
    }

    private func save() {
        guard !isWorking, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        error = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await commit(name)
                dismiss()
            } catch {
                self.error = FolderEditText.message(error, doing: actionTitle == "Rename" ? "renamed" : "made")
            }
        }
    }
}
