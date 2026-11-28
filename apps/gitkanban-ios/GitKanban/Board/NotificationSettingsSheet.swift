import AuthenticationServices
import GitKanbanKit
import SwiftUI

/// What Tasks tells you about, and whether iOS lets it.
struct NotificationSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
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
                if model.notifiesReviews, model.notificationsAllowed == true, !providerRepos.isEmpty {
                    Section {
                        ForEach(providerRepos) { repo in instantRow(repo) }
                        Toggle("Urgent requests only", isOn: $model.notifiesUrgentReviewsOnly)
                    } header: {
                        Text("Instant review notifications")
                    } footer: {
                        Text("A review request reaches this iPhone the moment it is asked, through the GitKittie relay. Urgent requests break through Focus. With Urgent requests only, the others still count on the app icon.")
                    }
                }
                Section {
                    Toggle("Count on the app icon", isOn: $model.badgesReviews)
                } footer: {
                    Text("The number of items waiting for your review.")
                }
                Section {
                } footer: {
                    Text("Without instant notifications, Tasks looks for news while it is open and whenever iOS gives it time in the background, so a notification can arrive some time after the change.")
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: scenePhase) {
                await model.refreshNotificationPermission()
                await model.registerForReviewPushes()
            }
        }
    }

    private var providerRepos: [AddedRepo] { model.addedRepos.filter { !$0.kind.isFolder } }

    /// One repo: on, or the one step that turns it on.
    @ViewBuilder private func instantRow(_ repo: AddedRepo) -> some View {
        switch model.instantNotifications[repo.id] {
        case .on:
            LabeledContent(repo.displayName) { Label("On", systemImage: "bolt.fill").foregroundStyle(.green) }
        case .needsInstall(let url):
            Button {
                Task {
                    // GitHub's page installs GitKittie Tasks on the repo and comes back to
                    // gitkittie-tasks://github-installed. Look again either way: it may have been
                    // installed without coming back.
                    _ = try? await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "gitkittie-tasks")
                    await model.registerForReviewPushes()
                }
            } label: {
                LabeledContent(repo.displayName) { Text("Turn On") }
            }
            .accessibilityHint("Installs GitKittie Tasks on this repository on GitHub")
        case .needsChannel:
            Button {
                Task { await model.turnOnInstantNotifications(for: repo.id) }
            } label: {
                LabeledContent(repo.displayName) { Text("Turn On") }
            }
            .accessibilityHint("Adds a webhook to this repository that tells the relay about new review requests")
        case .unavailable(let reason):
            LabeledContent(repo.displayName) { Text(reason).font(.footnote).foregroundStyle(.secondary) }
        case nil:
            LabeledContent(repo.displayName) { Text("Checking…").foregroundStyle(.secondary) }
        }
    }
}
