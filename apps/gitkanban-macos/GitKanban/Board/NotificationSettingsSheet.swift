import AppKit
import GitKanbanKit
import SwiftUI

/// What Tasks tells you about, and whether macOS lets it.
struct NotificationSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 480)
        .task(id: scenePhase) { await model.refreshNotificationPermission() }
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
