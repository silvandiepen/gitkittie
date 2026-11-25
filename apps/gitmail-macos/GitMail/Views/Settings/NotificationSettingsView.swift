import MailCore
import MailStore
import SwiftUI

/// Settings ▸ Notifications: which new mail may notify, per account, space and list (GKM-018,
/// GKM-037). Quiet by default: only new mail in Focused notifies and counts on the Dock badge.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model

    private var attention: MailAttention { model.attention }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("New mail in Focused notifies you and counts on the Dock badge. Promotions, newsletters and routine updates stay silent. Every view keeps its own unread count.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if attention.permission == .denied {
                    Notice(systemImage: "bell.slash", tint: .orange,
                           text: "Notifications are turned off for GitKittie Mail in System Settings › Notifications. The badge still works.")
                }

                if model.accounts.isEmpty {
                    Text("Add an account to choose its notifications.").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ACCOUNTS").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                        ForEach(model.accounts) { account in
                            Picker(account.displayName, selection: level(account.id)) {
                                Text("New Mail in Focused").tag(NotificationSettings.AccountLevel.focused)
                                Text("Off").tag(NotificationSettings.AccountLevel.off)
                            }
                        }
                    }
                }

                if !model.spaces.spaces.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SPACES").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                        ForEach(model.spaces.spaces) { space in
                            Picker(selection: level(space.id)) {
                                Text("Like the Rest of Focused").tag(NotificationSettings.SpaceLevel.automatic)
                                Text("Always").tag(NotificationSettings.SpaceLevel.always)
                                Text("Never").tag(NotificationSettings.SpaceLevel.muted)
                            } label: {
                                Label(space.name, systemImage: space.icon)
                            }
                        }
                        Text("Always notifies for new mail in the space wherever it lives, except Quarantine. Never keeps it silent, even from a list set to Always.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                let lists = attention.settings.customLists
                if !lists.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LISTS").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                        ForEach(lists, id: \.key) { entry in
                            HStack {
                                Text(entry.key.list).lineLimit(1).truncationMode(.middle)
                                Text(model.accounts.first { $0.id == entry.key.account }?.displayName ?? "")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.level == .always ? "Always" : "Never").foregroundStyle(.secondary)
                                Button("Reset") {
                                    Task { await attention.setLevel(.automatic, list: entry.key.list, account: entry.key.account, accounts: model.accounts) }
                                }
                                .buttonStyle(.link)
                            }
                            .font(.callout)
                        }
                    }
                }
                Text("Choose a list’s notifications from any of its messages: Correct › Notifications for This List.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 360)
        // The person may have changed it in System Settings since.
        .task { await attention.refreshPermission() }
    }

    private func level(_ space: MailSpaceID) -> Binding<NotificationSettings.SpaceLevel> {
        Binding(
            get: { attention.settings.level(space: space) },
            set: { level in Task { await attention.setLevel(level, space: space, accounts: model.accounts) } }
        )
    }

    private func level(_ account: MailAccountID) -> Binding<NotificationSettings.AccountLevel> {
        Binding(
            get: { attention.settings.level(account) },
            set: { level in Task { await attention.setLevel(level, for: account, accounts: model.accounts) } }
        )
    }
}
