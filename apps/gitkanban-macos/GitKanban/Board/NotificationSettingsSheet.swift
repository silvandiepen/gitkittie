import AppKit
import AuthenticationServices
import GitKanbanKit
import SwiftUI

/// What Tasks tells you about, and whether macOS lets it.
struct NotificationSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(
                title: "Notifications",
                detail: "Choose what Tasks tells you about. It looks for news every few minutes while it is running."
            )

            SettingsPanel { permissionRow }

            VStack(alignment: .leading, spacing: 8) {
                Text("Tell me about").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                SettingsPanel {
                    SettingsToggleRow(icon: "checkmark.seal.fill", tint: .orange, title: "Reviews to do",
                                      detail: "A request with items waiting for your answer.", isOn: $model.notifiesReviews)
                    SettingsDivider()
                    SettingsToggleRow(icon: "arrow.left.arrow.right", tint: .blue, title: "New and moved tasks",
                                      detail: "Changes on a board since you last opened it.", isOn: $model.notifiesBoardChanges)
                    SettingsDivider()
                    SettingsToggleRow(icon: "app.badge.fill", tint: .red, title: "Count on the Dock icon",
                                      detail: "How many items are waiting for your review.", isOn: $model.badgesReviews)
                }
                .disabled(model.notificationsAllowed == false)
            }

            if model.notifiesReviews, model.notificationsAllowed == true, !providerRepos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Instant review notifications").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    SettingsPanel {
                        ForEach(providerRepos) { repo in
                            instantRow(repo)
                            SettingsDivider()
                        }
                        SettingsToggleRow(icon: "exclamationmark.circle.fill", tint: .red, title: "Urgent requests only",
                                          detail: "Others still count on the Dock icon.", isOn: $model.notifiesUrgentReviewsOnly)
                    }
                    Text("A review request reaches this Mac the moment it is asked, through the GitKittie relay, even while Tasks is closed. Urgent requests break through Focus.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 480)
        .task(id: scenePhase) {
            await model.refreshNotificationPermission()
            await model.registerForReviewPushes()
        }
    }

    private var providerRepos: [AddedRepo] { model.addedRepos.filter { !$0.kind.isFolder } }

    /// One repo: on, or the one step that turns it on.
    @ViewBuilder private func instantRow(_ repo: AddedRepo) -> some View {
        switch model.instantNotifications[repo.id] {
        case .on:
            SettingsRow(icon: "bolt.fill", tint: .green, title: repo.displayName, detail: "On") { EmptyView() }
        case .needsInstall(let url):
            SettingsRow(icon: "bolt.slash.fill", tint: .gray, title: repo.displayName,
                        detail: "Install GitKittie Tasks on this repository on GitHub.") {
                Button("Turn On…") {
                    Task {
                        // GitHub's page comes back to gitkittie-tasks://github-installed. Look
                        // again either way: it may have been installed without coming back.
                        _ = try? await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "gitkittie-tasks")
                        await model.registerForReviewPushes()
                    }
                }
                .controlSize(.small)
            }
        case .needsChannel:
            SettingsRow(icon: "bolt.slash.fill", tint: .gray, title: repo.displayName,
                        detail: "Tasks adds a webhook to the repository that tells the relay about new requests.") {
                Button("Turn On") { Task { await model.turnOnInstantNotifications(for: repo.id) } }.controlSize(.small)
            }
        case .unavailable(let reason):
            SettingsRow(icon: "bolt.slash.fill", tint: .orange, title: repo.displayName, detail: reason) { EmptyView() }
        case nil:
            SettingsRow(icon: "bolt.fill", tint: .gray, title: repo.displayName, detail: "Checking…") { EmptyView() }
        }
    }

    /// Whether macOS lets Tasks notify, and the one thing to do about it when it does not.
    @ViewBuilder private var permissionRow: some View {
        switch model.notificationsAllowed {
        case .some(true):
            SettingsRow(icon: "bell.badge.fill", tint: .green, title: "Notifications are allowed",
                        detail: "Change how they look in System Settings.") {
                Button("System Settings…", action: openSystemSettings).controlSize(.small)
            }
        case .some(false):
            SettingsRow(icon: "bell.slash.fill", tint: .orange, title: "Notifications are off for Tasks",
                        detail: "Turn them on in System Settings to get any of these.") {
                Button("Open System Settings", action: openSystemSettings).controlSize(.small)
            }
        case .none:
            SettingsRow(icon: "bell.fill", tint: .gray, title: "Notifications are not set up",
                        detail: "macOS asks once whether Tasks may notify you.") {
                Button("Allow…") { Task { await model.requestNotificationPermission() } }.controlSize(.small)
            }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
