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
        VStack(alignment: .leading, spacing: 16) {
            Text("Notifications").font(.headline)
            Group {
                switch model.notificationsAllowed {
                case .some(true):
                    Label("Notifications are allowed", systemImage: "bell.badge.fill").foregroundStyle(.green)
                case .some(false):
                    HStack {
                        Label("Notifications are turned off for Tasks", systemImage: "bell.slash").foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                case .none:
                    Button { Task { await model.requestNotificationPermission() } } label: {
                        Label("Allow Notifications", systemImage: "bell.badge")
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Tell me about").font(.subheadline.weight(.semibold))
                Toggle("Reviews to do", isOn: $model.notifiesReviews)
                Text("A request with items waiting for your answer.").font(.caption).foregroundStyle(.secondary)
                Toggle("New and moved tasks", isOn: $model.notifiesBoardChanges)
                Text("Changes on a board since you last opened it.").font(.caption).foregroundStyle(.secondary)
                Toggle("Count on the Dock icon", isOn: $model.badgesReviews)
                Text("The number of items waiting for your review.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Tasks looks for news every few minutes while it is running.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: scenePhase) { await model.refreshNotificationPermission() }
    }
}
