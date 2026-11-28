import GitKanbanKit
import SwiftUI

/// What Tasks tells you about, and whether iOS lets it.
struct NotificationSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Group {
                    Section {
                        switch model.notificationsAllowed {
                        case .some(true):
                            Label("Notifications are allowed", systemImage: "bell.badge.fill").foregroundStyle(.green)
                        case .some(false):
                            Label("Notifications are turned off for Tasks", systemImage: "bell.slash").foregroundStyle(.orange)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        case .none:
                            Button {
                                Task { await model.requestNotificationPermission() }
                            } label: { Label("Allow Notifications", systemImage: "bell.badge") }
                            .accessibilityIdentifier("allowNotificationsButton")
                        }
                    }
                    Section {
                        Toggle("Reviews to do", isOn: $model.notifiesReviews)
                        Toggle("New and moved tasks", isOn: $model.notifiesBoardChanges)
                    } header: {
                        Text("Tell me about")
                    } footer: {
                        Text("Reviews to do: a request with items waiting for your answer. New and moved tasks: changes on a board since you last opened it.")
                    }
                    Section {
                        Toggle("Count on the app icon", isOn: $model.badgesReviews)
                    } footer: {
                        Text("The number of items waiting for your review.")
                    }
                    Section {
                    } footer: {
                        Text("Tasks looks for news while it is open and whenever iOS gives it time in the background, so a notification can arrive some time after the change. With Tasks open on your Mac, the Mac notices within a few minutes.")
                    }
                }
                // Rows on the navy, not the system grey (GITKITTIE-095).
                .themedRows()
            }
            .themedList()
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: scenePhase) { await model.refreshNotificationPermission() }
        }
    }
}
