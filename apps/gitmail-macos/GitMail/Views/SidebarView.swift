import MailCore
import SwiftUI

/// All Mail, then the accounts. Folders come from the provider and appear after a sync.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: { model.selection },
            set: { new in Task { await model.select(new ?? .allMail) } }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "tray.full")
                        .font(.body)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text("All Mail").font(.body.weight(.medium))
                    Spacer(minLength: 4)
                    if model.totalCount > 0 {
                        Text("\(model.totalCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(model.totalCount) messages")
                    }
                }
                .padding(.vertical, 3)
                .tag(SidebarSelection.allMail)
            }

            Section("Accounts") {
                if model.accounts.isEmpty {
                    Text("No accounts yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .selectionDisabled()
                }
                ForEach(model.accounts) { account in
                    AccountRow(account: account)
                        .tag(SidebarSelection.account(account.id))
                    ForEach(model.folders[account.id] ?? [], id: \.self) { folder in
                        Label(folder, systemImage: folder.caseInsensitiveCompare("INBOX") == .orderedSame ? "tray" : "folder")
                            .font(.callout)
                            .padding(.leading, 30)
                            .tag(SidebarSelection.folder(account.id, folder))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    /// What to add on the left, the app's settings on the right — as in Tasks.
    private var footer: some View {
        HStack {
            Menu {
                Button("Add Account…", systemImage: "at") {}
                    .disabled(true)
                Text("Adding an account isn’t available in this build yet.")
            } label: {
                Label("Add", systemImage: "plus").font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add an account")

            Spacer()

            Menu {
                if let folder = model.mailFolder {
                    Button("Show Mail Folder in Finder", systemImage: "folder") { Platform.reveal(folder) }
                }
                Button("Rebuild Search Index", systemImage: "arrow.clockwise") { Task { await model.rebuildIndex() } }
                    .disabled(model.isRebuildingIndex)
            } label: {
                Image(systemName: "gearshape").font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct AccountRow: View {
    let account: MailAccount

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName).font(.body).lineLimit(1)
                if !account.address.isEmpty, account.address != account.displayName {
                    Text(account.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
