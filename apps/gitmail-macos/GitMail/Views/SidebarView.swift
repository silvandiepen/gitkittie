import MailCore
import SwiftUI

/// Focused and the category views with All Mail, then sending, then the accounts. Folders come
/// from the provider and appear after a sync.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(MailWindowRequests.self) private var requests
    @Environment(SettingsNavigation.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @State private var updates = AppUpdates()

    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: { model.selection },
            set: { new in Task { await model.select(new ?? .category(.focused)) } }
        )
    }

    var body: some View {
        List(selection: selection) {
            CategorySidebarSection()

            SendingSidebarSection()

            SpacesSidebarSection()

            AccountsSidebarSection()
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // The disk is nearly full: nothing downloads until there is room (MAIL-106).
                if let pause = model.sync.downloadPause {
                    DownloadPausedNotice(pause: pause) { settings.show(.storage, with: openSettings) }
                        .padding(.horizontal, 10).padding(.top, 6)
                }
                // A newer Mail in the App Store: Update opens its page there.
                if updates.offer != nil {
                    UpdateAvailableNotice(updates: updates).padding(.horizontal, 10).padding(.top, 6)
                }
                footer
            }
        }
        .checksForAppUpdates(updates)
    }

    /// What to add on the left, the app's settings on the right — as in Tasks. The Mailbox menu
    /// has every item too, for the keyboard.
    private var footer: some View {
        HStack {
            Menu {
                Button("Add Account…", systemImage: "at") { requests.accountSheet = .add }
                Button("New Space…", systemImage: "square.stack.3d.up") { requests.spaceSheet = .create }
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
                Button("Use Another Mail Folder…", systemImage: "folder.badge.gearshape") { Task { await MailFolderChoice.chooseAnother(model) } }
                if !model.usesDefaultMailFolder {
                    Button("Use the Default Mail Folder", systemImage: "arrow.uturn.backward") { Task { await model.useMailFolder(nil) } }
                }
                Divider()
                Button("Notifications…", systemImage: "bell.badge") { settings.show(.notifications, with: openSettings) }
                Button("Settings…", systemImage: "gearshape") { settings.show(.general, with: openSettings) }
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
}
