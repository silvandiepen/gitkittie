import MailCore
import MailStore
import SwiftUI
import UIKit

/// Which new mail may notify, per account, space and list (GKM-018, GKM-037): the same choices
/// as on the Mac, and as honest about timing as the rest of Settings (MAIL-053).
struct NotificationsScreen: View {
    @Environment(AppModel.self) private var model

    private var attention: MailAttention { model.attention }

    var body: some View {
        Form {
            if attention.permission == .denied {
                Section {
                    NoticeLine(systemImage: "bell.slash", tint: .orange,
                               text: "Notifications are off for Mail in Settings ▸ Notifications.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }

            Section {
                if model.accounts.isEmpty {
                    Text("Add an account to choose its notifications.").foregroundStyle(.secondary)
                }
                ForEach(model.accounts, id: \.id) { account in
                    Picker(account.displayName, selection: level(account.id)) {
                        Text("New Mail in Focused").tag(NotificationSettings.AccountLevel.focused)
                        Text("Off").tag(NotificationSettings.AccountLevel.off)
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("New mail in Focused notifies you; promotions, newsletters and routine updates stay silent. When Mail isn’t open it checks for new mail only when iOS lets it, so a notification can come minutes or hours after the mail. Tap one to open its conversation.")
            }

            if !model.spaces.spaces.isEmpty {
                Section {
                    ForEach(model.spaces.spaces) { space in
                        Picker(selection: level(space.id)) {
                            Text("Like the Rest of Focused").tag(NotificationSettings.SpaceLevel.automatic)
                            Text("Always").tag(NotificationSettings.SpaceLevel.always)
                            Text("Never").tag(NotificationSettings.SpaceLevel.muted)
                        } label: {
                            Label(space.name, systemImage: space.icon)
                        }
                    }
                } header: {
                    Text("Spaces")
                } footer: {
                    Text("Always notifies for new mail in the space wherever it lives, except Quarantine. Never keeps it silent, even from a list set to Always.")
                }
            }

            let lists = attention.settings.customLists
            if !lists.isEmpty {
                Section("Lists") {
                    ForEach(lists, id: \.key) { entry in
                        LabeledContent {
                            Text(entry.level == .always ? "Always" : "Never")
                        } label: {
                            Text(entry.key.list).lineLimit(1).truncationMode(.middle)
                            Text(model.accounts.first { $0.id == entry.key.account }?.displayName ?? "")
                        }
                        .swipeActions {
                            Button("Reset") {
                                Task { await attention.setLevel(.automatic, list: entry.key.list, account: entry.key.account, accounts: model.accounts) }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.window.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        // The person may have changed it in Settings since.
        .task { await attention.refreshPermission() }
    }

    private func level(_ account: MailAccountID) -> Binding<NotificationSettings.AccountLevel> {
        Binding(
            get: { attention.settings.level(account) },
            set: { level in Task { await attention.setLevel(level, for: account, accounts: model.accounts) } }
        )
    }

    private func level(_ space: MailSpaceID) -> Binding<NotificationSettings.SpaceLevel> {
        Binding(
            get: { attention.settings.level(space: space) },
            set: { level in Task { await attention.setLevel(level, space: space, accounts: model.accounts) } }
        )
    }
}
