import MailCore
import SwiftUI

/// All Mail, then the accounts. Folders come from the provider and appear after a sync.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: AccountSheet?

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

            AccountsSidebarSection(sheet: $sheet)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .sheet(item: $sheet) { $0.view }
    }

    /// What to add on the left, the app's settings on the right — as in Tasks.
    private var footer: some View {
        HStack {
            Menu {
                Button("Add Account…", systemImage: "at") { sheet = .add }
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
                Button("Use Another Mail Folder…", systemImage: "folder.badge.gearshape") { chooseMailFolder() }
                if !model.usesDefaultMailFolder {
                    Button("Use the Default Mail Folder", systemImage: "arrow.uturn.backward") { Task { await model.useMailFolder(nil) } }
                }
                Divider()
                if model.sync.isRunning {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { Task { await model.sync.syncNow() } }
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
