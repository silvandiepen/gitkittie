import MailCore
import SwiftUI

/// Which new mail may notify, per account and per list (GKM-018). Quiet by default: only new
/// mail in Focused notifies and counts on the Dock badge.
struct NotificationSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var attention: MailAttention { model.attention }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notifications").font(.title2.weight(.semibold))
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

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func level(_ account: MailAccountID) -> Binding<NotificationSettings.AccountLevel> {
        Binding(
            get: { attention.settings.level(account) },
            set: { level in Task { await attention.setLevel(level, for: account, accounts: model.accounts) } }
        )
    }
}
