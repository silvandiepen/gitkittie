import SwiftUI

/// Mail ▸ Settings… (⌘,), GKM-066: every setting in one standard window, a tab each for the
/// accounts and their mailboxes, notifications, storage and the rest.
struct SettingsView: View {
    @Environment(SettingsNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AccountsSettingsTab()
                .tabItem { Label("Accounts", systemImage: "at") }
                .tag(SettingsTab.accounts)
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(SettingsTab.notifications)
            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsTab.storage)
        }
        .scenePadding()
        .frame(width: 780)
        .background(SolidWindow())
    }
}
